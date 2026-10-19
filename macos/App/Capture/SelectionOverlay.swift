import AppKit

/// Full-screen overlay on every display for picking a region, a window, or a
/// whole display. Internally works in AppKit screen coordinates; results are
/// converted to global capture space (top-left origin).
@MainActor
final class SelectionOverlay {
    enum Mode {
        /// Drag a region. Space toggles window picking.
        case region
        /// Hover and click a window.
        case window
        /// Drag a region, click a window, or press Return for the display.
        case allInOne
    }

    enum Result {
        case region(CGRect)
        case window(CGWindowID)
        case display(CGRect)
        case cancelled
    }

    /// Keeps the active overlay alive while it is on screen.
    private static var active: SelectionOverlay?

    fileprivate let state: OverlayState
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Result, Never>?
    private var previousApp: NSRunningApplication?

    static func present(mode: Mode) async -> Result {
        if let existing = active { existing.finish(.cancelled) }
        let overlay = SelectionOverlay(mode: mode)
        active = overlay
        return await withCheckedContinuation { c in
            overlay.continuation = c
            overlay.show()
        }
    }

    private init(mode: Mode) {
        state = OverlayState(mode: mode, windows: WindowList.onScreen())
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        state.mouse = NSEvent.mouseLocation
        state.updateHover()
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), overlay: self)
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        let keyPanel = panels.first { $0.frame.contains(state.mouse) } ?? panels.first
        keyPanel?.makeKey()
        keyPanel?.makeFirstResponder(keyPanel?.contentView)
        NSCursor.crosshair.push()
    }

    fileprivate func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    fileprivate func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        if Self.active === self { Self.active = nil }
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        continuation.resume(returning: result)
    }

    // MARK: - Input

    fileprivate func mouseDown() {
        state.mouse = NSEvent.mouseLocation
        state.dragStart = state.mouse
        state.dragCurrent = state.mouse
        redraw()
    }

    fileprivate func mouseDragged() {
        guard let start = state.dragStart else { return }
        var p = NSEvent.mouseLocation
        // Keep the selection on the display where the drag started.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(start) }) {
            p.x = min(max(p.x, screen.frame.minX), screen.frame.maxX)
            p.y = min(max(p.y, screen.frame.minY), screen.frame.maxY)
        }
        state.dragCurrent = p
        state.mouse = p
        redraw()
    }

    fileprivate func mouseUp() {
        defer { state.dragStart = nil; state.dragCurrent = nil; redraw() }
        if let rect = state.selection, rect.width >= 4, rect.height >= 4, state.mode != .window {
            finish(.region(GlobalSpace.fromAppKit(rect)))
            return
        }
        if state.isPickingWindow, let hovered = state.hovered {
            finish(.window(hovered.id))
        }
    }

    fileprivate func mouseMoved() {
        state.mouse = NSEvent.mouseLocation
        state.updateHover()
        redraw()
    }

    fileprivate func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            finish(.cancelled)
        case 49 where state.mode == .region: // Space
            state.windowToggle.toggle()
            state.updateHover()
            redraw()
        case 36 where state.mode == .allInOne, 76 where state.mode == .allInOne: // Return / Enter
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(state.mouse) }) {
                finish(.display(GlobalSpace.fromAppKit(screen.frame)))
            }
        default:
            break
        }
    }
}

// MARK: - State

fileprivate final class OverlayState {
    let mode: SelectionOverlay.Mode
    let windows: [WindowList.Entry]
    var windowToggle = false
    var mouse: CGPoint = .zero
    var dragStart: CGPoint?
    var dragCurrent: CGPoint?
    var hovered: WindowList.Entry?

    init(mode: SelectionOverlay.Mode, windows: [WindowList.Entry]) {
        self.mode = mode
        self.windows = windows
    }

    var isPickingWindow: Bool {
        switch mode {
        case .window, .allInOne: true
        case .region: windowToggle
        }
    }

    /// Current drag rect in AppKit screen coordinates.
    var selection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var isDragging: Bool {
        guard let s = selection else { return false }
        return s.width >= 4 || s.height >= 4
    }

    func updateHover() {
        hovered = isPickingWindow && !isDragging
            ? windows.first { $0.frame.contains(mouse) }
            : nil
    }
}

/// On-screen, normal-level windows of other apps, front to back.
enum WindowList {
    struct Entry {
        let id: CGWindowID
        /// AppKit screen coordinates.
        let frame: CGRect
    }

    static func onScreen() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != pid,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.height >= 40
            else { return nil }
            return Entry(id: id, frame: GlobalSpace.toAppKit(rect))
        }
    }
}

// MARK: - Window and view

private final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private unowned let overlay: SelectionOverlay
    private var state: OverlayState { overlay.state }

    init(frame: CGRect, overlay: SelectionOverlay) {
        self.overlay = overlay
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { overlay.mouseDown() }
    override func mouseDragged(with event: NSEvent) { overlay.mouseDragged() }
    override func mouseUp(with event: NSEvent) { overlay.mouseUp() }
    override func mouseMoved(with event: NSEvent) { overlay.mouseMoved() }
    override func keyDown(with event: NSEvent) { overlay.keyDown(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        let origin = window.frame.origin
        let toLocal = { (r: CGRect) in r.offsetBy(dx: -origin.x, dy: -origin.y) }

        let hole: CGRect? = state.isDragging ? state.selection : state.hovered?.frame
        let dim = NSBezierPath(rect: bounds)
        if let hole {
            dim.append(NSBezierPath(rect: toLocal(hole)))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        if let hole {
            let local = toLocal(hole)
            if !state.isDragging {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                local.fill()
            }
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: local.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            if state.isDragging { drawSizeLabel(for: local) }
        } else if !state.isPickingWindow, window.frame.contains(state.mouse) {
            drawCrosshair(at: CGPoint(x: state.mouse.x - origin.x, y: state.mouse.y - origin.y))
        }

        drawHint()
    }

    private var scale: CGFloat { window?.screen?.backingScaleFactor ?? 2 }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        var p = CGPoint(x: rect.minX, y: rect.minY - 24)
        if p.y < 4 { p.y = rect.minY + 6 }
        drawPill(text, at: p)
    }

    private func drawCrosshair(at p: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: p.y + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y + 0.5))
        path.move(to: CGPoint(x: p.x + 0.5, y: 0))
        path.line(to: CGPoint(x: p.x + 0.5, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.stroke()
        let global = GlobalSpace.fromAppKit(CGRect(origin: state.mouse, size: .zero)).origin
        drawPill("\(Int(global.x)), \(Int(global.y))", at: CGPoint(x: p.x + 10, y: p.y - 26))
    }

    private func drawHint() {
        guard window?.frame.contains(state.mouse) == true else { return }
        let hint: String = switch state.mode {
        case .region: state.windowToggle ? "Click a window · Space for region · Esc to cancel" : "Drag to select · Space for window · Esc to cancel"
        case .window: "Click a window · Esc to cancel"
        case .allInOne: "Drag for region · Click a window · Return for full screen · Esc to cancel"
        }
        let size = (hint as NSString).size(withAttributes: Self.labelAttributes)
        drawPill(hint, at: CGPoint(x: bounds.midX - size.width / 2, y: 40))
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func drawPill(_ text: String, at origin: CGPoint) {
        let size = (text as NSString).size(withAttributes: Self.labelAttributes)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: Self.labelAttributes)
    }
}
