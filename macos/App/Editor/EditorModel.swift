import AppKit
import Combine
import SwiftUI

enum EditorTool: CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, text, freehand, counter
    case highlight, spotlight, blur, pixelate, redact, crop

    var id: Self { self }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .freehand: "Pen"
        case .counter: "Counter"
        case .highlight: "Highlight"
        case .spotlight: "Spotlight"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .redact: "Redact"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .freehand: "pencil.tip"
        case .counter: "1.circle"
        case .highlight: "highlighter"
        case .spotlight: "sun.max"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .redact: "rectangle.fill"
        case .crop: "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .freehand: "p"
        case .counter: "n"
        case .highlight: "h"
        case .spotlight: "s"
        case .blur: "b"
        case .pixelate: "x"
        case .redact: "d"
        case .crop: "c"
        }
    }

    /// Colour used until the user picks one explicitly.
    var defaultColor: NSColor {
        switch self {
        case .highlight: NSColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
        case .redact: .black
        default: NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    let source: CGImage
    let document: EditorDocument
    let effects: EffectCache

    /// Bumped after every document mutation so views re-read state.
    @Published private(set) var revision = 0
    @Published var tool: EditorTool = .arrow {
        didSet { toolDidChange(from: oldValue) }
    }
    @Published var selectedID: UInt64?
    @Published var pendingCrop: Rect?
    @Published var isEditingText = false
    @Published var zoomPercent = 100
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// Background styling; the last-used value is remembered across editors.
    @Published var background: BackgroundStyle = BackgroundStyle.loadSaved() {
        didSet { background.save() }
    }

    // Style state shown in the toolbar.
    @Published var strokeColor: NSColor = EditorTool.arrow.defaultColor { didSet { styleDidChange() } }
    @Published var lineWidth: Double = 4 { didSet { styleDidChange() } }
    @Published var fontSize: Double = 28 { didSet { styleDidChange() } }
    @Published var fillEnabled = false { didSet { styleDidChange() } }

    private(set) var annotations: [Annotation] = []
    private var colorChosenByUser = false
    private var loadingStyle = false
    private var styleTask: Task<Void, Never>?

    weak var canvas: CanvasView?
    var onClose: (() -> Void)?

    init(url: URL, source: CGImage) {
        self.url = url
        self.source = source
        self.document = EditorDocument(width: UInt32(source.width), height: UInt32(source.height), sourcePath: url.path)
        self.effects = EffectCache(source: source)
    }

    // MARK: Derived state

    var canUndo: Bool { _ = revision; return document.canUndo() }
    var canRedo: Bool { _ = revision; return document.canRedo() }
    var hasCrop: Bool { _ = revision; return document.crop() != nil }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    var sourceSize: CGSize { CGSize(width: source.width, height: source.height) }

    /// Transform used for display; the crop tool shows the uncropped image.
    var displayTransform: SourceTransform {
        SourceTransform(sourceSize: sourceSize,
                        crop: tool == .crop ? nil : document.crop()?.cgRect,
                        quarterTurns: Int(document.rotation()))
    }

    var exportTransform: SourceTransform {
        SourceTransform(sourceSize: sourceSize, crop: document.crop()?.cgRect, quarterTurns: Int(document.rotation()))
    }

    /// The crop tool shows the plain uncropped image, without background.
    var displayBackground: BackgroundStyle {
        var b = background
        if tool == .crop { b.enabled = false }
        return b
    }

    var displayLayout: BackgroundLayout { displayBackground.layout(contentSize: displayTransform.outputSize) }

    /// Size and image placement of the exported (styled) canvas.
    var exportLayout: BackgroundLayout { background.layout(contentSize: exportTransform.outputSize) }

    var currentStyle: AnnotationStyle {
        let c = strokeColor.usingColorSpace(.sRGB) ?? strokeColor
        let stroke = AnnotationColor(r: Float(c.redComponent), g: Float(c.greenComponent),
                                     b: Float(c.blueComponent), a: Float(c.alphaComponent))
        var fill: AnnotationColor?
        if fillEnabled { fill = AnnotationColor(r: stroke.r, g: stroke.g, b: stroke.b, a: 0.3) }
        return AnnotationStyle(stroke: stroke, fill: fill, lineWidth: lineWidth, fontSize: fontSize)
    }

    // MARK: Mutations

    private func didMutate() {
        annotations = document.annotations()
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil }
        revision += 1
    }

    private func perform(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            didMutate()
        } catch {
            errorMessage = "\(label) failed: \(error.localizedDescription)"
            didMutate()
        }
    }

    func reloadAnnotations() { didMutate() }

    func add(_ kind: AnnotationKind, style: AnnotationStyle? = nil) {
        flushStyle()
        perform("Add annotation") {
            let id = try document.addAnnotation(kind: kind, style: style ?? currentStyle)
            selectedID = id
        }
    }

    func replace(id: UInt64, kind: AnnotationKind) {
        guard let a = annotations.first(where: { $0.id == id }) else { return }
        flushStyle()
        perform("Update annotation") { try document.updateAnnotation(id: id, kind: kind, style: a.style) }
    }

    func move(ids: [UInt64], dx: Double, dy: Double) {
        guard dx != 0 || dy != 0, !ids.isEmpty else { return }
        flushStyle()
        perform("Move") { try document.moveAnnotations(ids: ids, dx: dx, dy: dy) }
    }

    func removeAnnotation(id: UInt64) {
        perform("Delete") { try document.removeAnnotation(id: id) }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        removeAnnotation(id: id)
    }

    func select(_ id: UInt64?) {
        guard id != selectedID else { return }
        flushStyle()
        selectedID = id
        if let a = selected { loadStyle(from: a.style) }
    }

    func undo() { flushStyle(); if document.undo() { didMutate() } }
    func redo() { flushStyle(); if document.redo() { didMutate() } }

    func rotate(clockwise: Bool) {
        perform("Rotate") { clockwise ? try document.rotateClockwise() : try document.rotateCounterClockwise() }
        pendingCrop = tool == .crop ? document.crop() : nil
    }

    // MARK: Crop

    func applyPendingCrop() {
        guard let pending = pendingCrop else { return }
        let bounds = CGRect(origin: .zero, size: sourceSize)
        let r = pending.cgRect.standardized.integral.intersection(bounds)
        if r.isNull || r.width < 1 || r.height < 1 {
            cancelCrop()
            return
        }
        perform("Crop") { try document.setCrop(crop: r == bounds ? nil : Rect(r)) }
        pendingCrop = nil
        tool = .select
    }

    func cancelCrop() {
        pendingCrop = document.crop()
        tool = .select
    }

    func resetCrop() {
        perform("Reset crop") { try document.setCrop(crop: nil) }
        pendingCrop = nil
        if tool == .crop { tool = .select }
    }

    // MARK: Tool and style handling

    private func toolDidChange(from old: EditorTool) {
        if old == .crop { pendingCrop = nil }
        if tool == .crop {
            pendingCrop = document.crop()
            selectedID = nil
        }
        if tool != .select, tool != .crop, selectedID != nil, tool != old { selectedID = nil }
        if !colorChosenByUser, tool != .select, tool != .crop {
            loadingStyle = true
            strokeColor = tool.defaultColor
            loadingStyle = false
        }
    }

    func chooseColor(_ color: NSColor) {
        colorChosenByUser = true
        strokeColor = color
    }

    private func loadStyle(from s: AnnotationStyle) {
        loadingStyle = true
        strokeColor = NSColor(srgbRed: CGFloat(s.stroke.r), green: CGFloat(s.stroke.g),
                              blue: CGFloat(s.stroke.b), alpha: CGFloat(s.stroke.a))
        lineWidth = s.lineWidth
        fontSize = s.fontSize
        fillEnabled = s.fill != nil
        loadingStyle = false
    }

    private func styleDidChange() {
        guard !loadingStyle, selectedID != nil else { return }
        styleTask?.cancel()
        styleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.flushStyle()
        }
    }

    /// Applies pending toolbar style edits to the selected annotation now.
    func flushStyle() {
        guard styleTask != nil else { return }
        styleTask?.cancel()
        styleTask = nil
        guard let a = selected else { return }
        var style = currentStyle
        // Only region-fill kinds carry a fill; leave others untouched.
        switch a.kind {
        case .rectangle, .ellipse: break
        default: style.fill = a.style.fill
        }
        guard style != a.style else { return }
        perform("Update style") { try document.updateAnnotation(id: a.id, kind: a.kind, style: style) }
    }
}
