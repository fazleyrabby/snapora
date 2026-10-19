import AppKit
import Combine
import SwiftUI

struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

/// Flipped (top-left origin) view that renders the document and handles all
/// mouse/keyboard editing. Document coordinates are source image pixels.
final class CanvasView: NSView, NSTextFieldDelegate {
    private let model: EditorModel
    private var bag = Set<AnyCancellable>()

    // View state.
    private var zoom: CGFloat = 1          // 1 == 100% (one image pixel per device pixel)
    private var pan: CGPoint = .zero
    private var isFit = true
    private var transform: SourceTransform

    // Interaction state.
    private enum Drag {
        case create(start: CGPoint, current: CGPoint, points: [CGPoint])
        case move(startSrc: CGPoint, id: UInt64, delta: CGPoint)
        case resizeRect(id: UInt64, handle: RectHandle, original: CGRect, current: CGRect)
        case resizeEndpoint(id: UInt64, isStart: Bool, point: CGPoint)
        case crop(start: CGPoint)
        case cropResize(handle: RectHandle, original: CGRect)
        case pan(last: CGPoint)
    }
    private var drag: Drag?

    // Inline text editing.
    private var textField: NSTextField?
    private var editingID: UInt64?
    private var editingOrigin: CGPoint = .zero
    private var finishingText = false

    init(model: EditorModel) {
        self.model = model
        self.transform = model.displayTransform
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.canvas = self
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.modelChanged() }
            }
            .store(in: &bag)
        #if DEBUG
        EditorGeometrySelfCheck.runOnce()
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var scale: CGFloat { ViewMapping.scale(zoom: zoom, backingScale: backing) }

    private var mapping: ViewMapping {
        let s = scale
        return ViewMapping(origin: ViewMapping.origin(outputSize: transform.outputSize, viewport: bounds.size, scale: s, pan: pan), scale: s)
    }

    private func toSource(_ viewPoint: CGPoint) -> CGPoint {
        transform.toSource(mapping.toOutput(viewPoint))
    }

    private func toView(sourceRect r: CGRect) -> CGRect {
        mapping.toView(transform.toOutput(r))
    }

    private func toView(source p: CGPoint) -> CGPoint {
        mapping.toView(transform.toOutput(p))
    }

    // MARK: Model sync and layout

    private func modelChanged() {
        transform = model.displayTransform
        if isFit { applyFit() }
        updateZoomPercent()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        modelChanged()
    }

    override func layout() {
        super.layout()
        if isFit { applyFit() }
        updateZoomPercent()
    }

    private func applyFit() {
        zoom = ViewMapping.fitZoom(outputSize: transform.outputSize, viewport: bounds.size, backingScale: backing)
        pan = .zero
    }

    private func updateZoomPercent() {
        let pct = Int((zoom * 100).rounded())
        if model.zoomPercent != pct {
            DispatchQueue.main.async { [model] in model.zoomPercent = pct }
        }
    }

    // MARK: Zoom commands

    func zoomIn() { setZoom(zoom * 1.25, anchor: center) }
    func zoomOut() { setZoom(zoom / 1.25, anchor: center) }
    func zoomToFit() { isFit = true; applyFit(); updateZoomPercent(); needsDisplay = true }
    func zoomActualSize() { setZoom(1, anchor: center) }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        isFit = false
        let anchorOut = mapping.toOutput(anchor)
        zoom = min(max(newZoom, 0.05), 32)
        let s = scale
        let base = ViewMapping.origin(outputSize: transform.outputSize, viewport: bounds.size, scale: s, pan: .zero)
        pan = CGPoint(x: anchor.x - anchorOut.x * s - base.x, y: anchor.y - anchorOut.y * s - base.y)
        clampPan()
        updateZoomPercent()
        needsDisplay = true
    }

    private func clampPan() {
        let s = scale
        let limX = (transform.outputSize.width * s + bounds.width) / 2 - 60
        let limY = (transform.outputSize.height * s + bounds.height) / 2 - 60
        pan.x = min(max(pan.x, -max(limX, 0)), max(limX, 0))
        pan.y = min(max(pan.y, -max(limY, 0)), max(limY, 0))
    }

    override func scrollWheel(with event: NSEvent) {
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        isFit = false
        pan.x += event.scrollingDeltaX * k
        pan.y += event.scrollingDeltaY * k
        clampPan()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    // MARK: Drawing

    private var displayedAnnotations: [Annotation] {
        var list = model.annotations
        switch drag {
        case .move(_, let id, let d):
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i] = list[i].translated(dx: d.x, dy: d.y)
            }
        case .resizeRect(let id, _, _, let cur):
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i].kind = list[i].kind.withRegionRect(Rect(cur))
            }
        case .resizeEndpoint(let id, let isStart, let p):
            if let i = list.firstIndex(where: { $0.id == id }) {
                switch list[i].kind {
                case .arrow(let s, let e):
                    list[i].kind = isStart ? .arrow(start: EditorPoint(p), end: e) : .arrow(start: s, end: EditorPoint(p))
                case .line(let s, let e):
                    list[i].kind = isStart ? .line(start: EditorPoint(p), end: e) : .line(start: s, end: EditorPoint(p))
                default: break
                }
            }
        default: break
        }
        if let id = editingID { list.removeAll { $0.id == id } }
        if case .create(let start, let current, let pts) = drag,
           let kind = AnnotationFactory.kind(for: model.tool, start: start, end: current, points: pts) {
            list.append(Annotation(id: 0, kind: kind, style: model.currentStyle))
        }
        return list
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.16, alpha: 1).setFill()
        bounds.fill()

        let m = mapping
        let out = CGRect(origin: .zero, size: transform.outputSize)

        ctx.saveGState()
        ctx.translateBy(x: m.origin.x, y: m.origin.y)
        ctx.scaleBy(x: m.scale, y: m.scale)
        ctx.clip(to: out)
        ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
        ctx.fill(out)
        ctx.interpolationQuality = m.scale * backing >= 1 ? .none : .high
        AnnotationRenderer.render(in: ctx, source: model.source, annotations: displayedAnnotations,
                                  transform: transform, cache: model.effects)
        ctx.restoreGState()

        drawOverlays(ctx)
    }

    private func drawOverlays(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor
        if model.tool == .crop, let crop = currentCropRect {
            let full = toView(sourceRect: CGRect(origin: .zero, size: model.sourceSize))
            let hole = toView(sourceRect: crop)
            let path = CGMutablePath()
            path.addRect(full)
            path.addRect(hole)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(1)
            ctx.stroke(hole)
            drawHandles(ctx, rect: crop)
        }
        guard model.tool == .select || model.tool == .crop || selectedForOverlay != nil else { return }
        if model.tool != .crop, let a = selectedForOverlay {
            let box = toView(sourceRect: a.selectionBounds)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(box)
            ctx.setLineDash(phase: 0, lengths: [])
            switch a.kind {
            case .arrow(let s, let e), .line(let s, let e):
                drawHandle(ctx, at: toView(source: s.cgPoint))
                drawHandle(ctx, at: toView(source: e.cgPoint))
            default:
                if let r = a.kind.regionRect { drawHandles(ctx, rect: r.cgRect.standardized) }
            }
        }
    }

    private var selectedForOverlay: Annotation? {
        guard let id = model.selectedID else { return nil }
        return displayedAnnotations.first { $0.id == id }
    }

    private func drawHandles(_ ctx: CGContext, rect: CGRect) {
        for h in RectHandle.all { drawHandle(ctx, at: toView(source: h.position(in: rect))) }
    }

    private func drawHandle(_ ctx: CGContext, at p: CGPoint) {
        let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
        ctx.setFillColor(.white)
        ctx.fill(r)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r)
    }

    private var currentCropRect: CGRect? { model.pendingCrop?.cgRect }

    override func resetCursorRects() {
        switch model.tool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Mouse

    private var hitTolerance: Double { 6 / Double(max(scale, 0.01)) }

    private func handleHit(in rect: CGRect, at viewPoint: CGPoint) -> RectHandle? {
        RectHandle.all.first { h in
            let p = toView(source: h.position(in: rect))
            return hypot(p.x - viewPoint.x, p.y - viewPoint.y) <= 7
        }
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil { commitText() }
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        let src = toSource(vp)

        if event.modifierFlags.contains(.option) || NSEvent.pressedMouseButtons & 0b100 != 0 {
            drag = .pan(last: vp)
            return
        }

        switch model.tool {
        case .select:
            if let a = model.selected {
                switch a.kind {
                case .arrow(let s, let e), .line(let s, let e):
                    for (isStart, pt) in [(true, s), (false, e)] {
                        let v = toView(source: pt.cgPoint)
                        if hypot(v.x - vp.x, v.y - vp.y) <= 7 {
                            drag = .resizeEndpoint(id: a.id, isStart: isStart, point: pt.cgPoint)
                            return
                        }
                    }
                default:
                    if let r = a.kind.regionRect?.cgRect.standardized, let h = handleHit(in: r, at: vp) {
                        drag = .resizeRect(id: a.id, handle: h, original: r, current: r)
                        return
                    }
                }
            }
            let hit = model.document.annotationAt(x: src.x, y: src.y, tolerance: hitTolerance)
            model.select(hit)
            if let hit {
                if event.clickCount == 2, case .text(let o, let t)? = model.selected?.kind {
                    beginTextEditing(at: o.cgPoint, text: t, id: hit)
                    return
                }
                drag = .move(startSrc: src, id: hit, delta: .zero)
            }
        case .text:
            model.select(nil)
            beginTextEditing(at: src, text: "", id: nil)
        case .counter:
            model.add(.counter(center: EditorPoint(src), number: model.document.nextCounterNumber()))
        case .crop:
            let full = CGRect(origin: .zero, size: model.sourceSize)
            if let r = model.pendingCrop?.cgRect, let h = handleHit(in: r, at: vp) {
                drag = .cropResize(handle: h, original: r)
            } else {
                drag = .crop(start: clamp(src, to: full))
            }
        default:
            drag = .create(start: src, current: src, points: [src])
        }
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        let src = toSource(vp)
        let shift = event.modifierFlags.contains(.shift)
        let full = CGRect(origin: .zero, size: model.sourceSize)

        switch drag {
        case .create(let start, _, var pts)?:
            let end = shift ? AnnotationFactory.constrained(model.tool, start: start, end: src) : src
            if model.tool == .freehand {
                if let last = pts.last, hypot(last.x - end.x, last.y - end.y) >= 1 / Double(scale) { pts.append(end) }
            }
            drag = .create(start: start, current: end, points: pts)
        case .move(let startSrc, let id, _)?:
            var d = CGPoint(x: src.x - startSrc.x, y: src.y - startSrc.y)
            if shift { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            drag = .move(startSrc: startSrc, id: id, delta: d)
        case .resizeRect(let id, let h, let original, _)?:
            drag = .resizeRect(id: id, handle: h, original: original, current: h.resized(original, to: src))
        case .resizeEndpoint(let id, let isStart, _)?:
            drag = .resizeEndpoint(id: id, isStart: isStart, point: src)
        case .crop(let start)?:
            model.pendingCrop = Rect(CGRect(from: start, to: clamp(src, to: full)))
        case .cropResize(let h, let original)?:
            let resized = h.resized(original, to: clamp(src, to: full))
            model.pendingCrop = Rect(resized)
        case .pan(let last)?:
            isFit = false
            pan.x += vp.x - last.x
            pan.y += vp.y - last.y
            clampPan()
            drag = .pan(last: vp)
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        switch drag {
        case .create(let start, let end, let pts)?:
            if let kind = AnnotationFactory.kind(for: model.tool, start: start, end: end, points: pts) {
                model.add(kind)
            }
        case .move(_, let id, let d)?:
            model.move(ids: [id], dx: d.x, dy: d.y)
        case .resizeRect(let id, _, _, let cur)?:
            if let a = model.annotations.first(where: { $0.id == id }), cur.width >= 1, cur.height >= 1 {
                model.replace(id: id, kind: a.kind.withRegionRect(Rect(cur)))
            }
        case .resizeEndpoint(let id, let isStart, let p)?:
            if let a = model.annotations.first(where: { $0.id == id }) {
                switch a.kind {
                case .arrow(let s, let e):
                    model.replace(id: id, kind: isStart ? .arrow(start: EditorPoint(p), end: e) : .arrow(start: s, end: EditorPoint(p)))
                case .line(let s, let e):
                    model.replace(id: id, kind: isStart ? .line(start: EditorPoint(p), end: e) : .line(start: s, end: EditorPoint(p)))
                default: break
                }
            }
        case .crop, .cropResize:
            if let r = model.pendingCrop?.cgRect, r.width < 2 || r.height < 2 { model.pendingCrop = model.document.crop() }
        case .pan, nil:
            break
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            if model.selectedID != nil { model.deleteSelected() } else { NSSound.beep() }
            return
        case 36, 76: // return, enter
            if model.tool == .crop { model.applyPendingCrop(); return }
        case 53: // escape
            if model.tool == .crop { model.cancelCrop() } else if model.selectedID != nil { model.select(nil) } else { model.tool = .select }
            return
        case 123, 124, 125, 126:
            if let id = model.selectedID, mods.isEmpty {
                let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
                let d: (Double, Double) = switch event.keyCode {
                case 123: (-step, 0)
                case 124: (step, 0)
                case 125: (0, step)
                default: (0, -step)
                }
                model.move(ids: [id], dx: d.0, dy: d.1)
                return
            }
        default: break
        }
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.shortcut == ch }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Inline text editing

    private func beginTextEditing(at origin: CGPoint, text: String, id: UInt64?) {
        finishingText = false
        editingID = id
        editingOrigin = origin
        let style = id.flatMap { i in model.annotations.first { $0.id == i }?.style } ?? model.currentStyle
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AnnotationRenderer.font(size: style.fontSize * Double(scale))
        field.textColor = NSColor(cgColor: AnnotationRenderer.color(style.stroke))
        field.placeholderString = "Text"
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.borderWidth = 1
        let p = toView(source: origin)
        field.frame = NSRect(x: p.x, y: p.y, width: 160, height: ceil(style.fontSize * Double(scale) * 1.3))
        addSubview(field)
        textField = field
        model.isEditingText = true
        window?.makeFirstResponder(field)
        resizeTextField()
        needsDisplay = true
    }

    private func resizeTextField() {
        guard let field = textField else { return }
        let w = max(60, field.attributedStringValue.size().width + 16)
        field.setFrameSize(NSSize(width: w, height: field.frame.height))
    }

    func controlTextDidChange(_ obj: Notification) { resizeTextField() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText(cancel: true)
            return true
        }
        return false
    }

    private func commitText(cancel: Bool = false) {
        guard let field = textField, !finishingText else { return }
        finishingText = true
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = editingID
        let origin = editingOrigin
        field.removeFromSuperview()
        textField = nil
        editingID = nil
        model.isEditingText = false
        window?.makeFirstResponder(self)
        if !cancel {
            if let id {
                if text.isEmpty { model.removeAnnotation(id: id) } else { model.replace(id: id, kind: .text(origin: EditorPoint(origin), text: text)) }
            } else if !text.isEmpty {
                model.add(.text(origin: EditorPoint(origin), text: text))
            }
        }
        needsDisplay = true
    }
}
