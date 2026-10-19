import AppKit
import SwiftUI

/// Full-screen overlay on every display for choosing what to capture or
/// record: an area, a window, or a whole display. A capture bar at the bottom
/// switches modes and, for recordings, holds audio/cursor options and the
/// Record button.
///
/// Internally works in AppKit screen coordinates; results are converted to
/// global capture space (top-left origin).
@MainActor
final class SelectionOverlay {
    enum Intent { case screenshot, recording }

    enum Mode: String, CaseIterable, Identifiable {
        case area, window, display
        var id: String { rawValue }
    }

    enum Target {
        /// Global capture-space rect.
        case region(CGRect)
        case window(CGWindowID)
        /// Global capture-space frame of the chosen display.
        case display(CGRect)
    }

    struct Selection {
        let intent: Intent
        let target: Target
    }

    struct Options {
        var showsBar = true
        /// All-in-One: the bar can switch between screenshot and recording.
        var allowsIntentSwitch = false
    }

    /// Keeps the active overlay alive while it is on screen.
    private static var active: SelectionOverlay?

    fileprivate let state: OverlayState
    private let options: Options
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var previousApp: NSRunningApplication?

    /// Returns nil when cancelled.
    static func present(intent: Intent, mode: Mode, options: Options = .init()) async -> Selection? {
        active?.finish(nil)
        let overlay = SelectionOverlay(intent: intent, mode: mode, options: options)
        active = overlay
        return await withCheckedContinuation { c in
            overlay.continuation = c
            overlay.show()
        }
    }

    private init(intent: Intent, mode: Mode, options: Options) {
        state = OverlayState(intent: intent, mode: mode, windows: WindowList.onScreen())
        self.options = options
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        state.mouse = NSEvent.mouseLocation
        state.updateHover()
        let barScreen = NSScreen.screens.first { $0.frame.contains(state.mouse) } ?? NSScreen.main
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), overlay: self)
            panel.contentView = view
            if options.showsBar, screen == barScreen { addBar(to: view) }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        let keyPanel = panels.first { $0.frame.contains(state.mouse) } ?? panels.first
        keyPanel?.makeKey()
        keyPanel?.makeFirstResponder(keyPanel?.contentView)
        NSCursor.crosshair.push()
    }

    private func addBar(to view: NSView) {
        let bar = NSHostingView(rootView: CaptureBar(
            state: state,
            settings: Settings.shared,
            allowsIntentSwitch: options.allowsIntentSwitch,
            setMode: { [weak self] in self?.setMode($0) },
            setIntent: { [weak self] in self?.setIntent($0) },
            confirm: { [weak self] in self?.confirm() },
            cancel: { [weak self] in self?.finish(nil) }
        ))
        let size = bar.fittingSize
        bar.frame = CGRect(x: (view.bounds.width - size.width) / 2, y: 48, width: size.width, height: size.height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin]
        view.addSubview(bar)
        state.barFrames.append { [weak bar, weak view] in
            guard let bar, let window = view?.window else { return nil }
            return bar.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        }
    }

    fileprivate func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    fileprivate func finish(_ selection: Selection?) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        if Self.active === self { Self.active = nil }
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        continuation.resume(returning: selection)
    }

    // MARK: - Mode / intent

    fileprivate func setMode(_ mode: Mode) {
        state.mode = mode
        state.clearChoice()
        state.updateHover()
        redraw()
    }

    fileprivate func setIntent(_ intent: Intent) {
        state.intent = intent
        state.clearChoice()
        redraw()
    }

    /// Record button / Return.
    fileprivate func confirm() {
        if let target = state.chosenTarget() {
            finish(Selection(intent: state.intent, target: target))
        } else if state.intent == .screenshot || state.mode == .display,
                  let screen = state.screenUnderMouse {
            finish(Selection(intent: state.intent, target: .display(GlobalSpace.fromAppKit(screen.frame))))
        }
    }

    // MARK: - Mouse

    fileprivate func mouseDown() {
        let p = NSEvent.mouseLocation
        state.mouse = p
        guard state.mode == .area else { return }

        if let committed = state.committed {
            if let corner = Handle.hit(p, rect: committed) {
                state.drag = .resizing(anchor: corner.opposite(in: committed))
                return
            }
            if committed.contains(p) {
                state.drag = .moving(offset: CGPoint(x: p.x - committed.minX, y: p.y - committed.minY), size: committed.size)
                return
            }
        }
        state.committed = nil
        state.drag = .selecting(start: p)
        state.dragCurrent = p
        redraw()
    }

    fileprivate func mouseDragged() {
        var p = NSEvent.mouseLocation
        // Keep selections on one display.
        let anchorPoint: CGPoint? = switch state.drag {
        case .selecting(let start): start
        case .resizing(let anchor): anchor
        case .moving: state.committed.map { CGPoint(x: $0.midX, y: $0.midY) }
        case nil: nil
        }
        if let a = anchorPoint, let screen = NSScreen.screens.first(where: { $0.frame.contains(a) }) {
            p.x = min(max(p.x, screen.frame.minX), screen.frame.maxX)
            p.y = min(max(p.y, screen.frame.minY), screen.frame.maxY)
        }
        state.mouse = p
        switch state.drag {
        case .selecting:
            state.dragCurrent = p
        case .resizing(let anchor):
            state.committed = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                     width: abs(anchor.x - p.x), height: abs(anchor.y - p.y))
        case .moving(let offset, let size):
            var r = CGRect(origin: CGPoint(x: p.x - offset.x, y: p.y - offset.y), size: size)
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) {
                r.origin.x = min(max(r.minX, screen.frame.minX), screen.frame.maxX - r.width)
                r.origin.y = min(max(r.minY, screen.frame.minY), screen.frame.maxY - r.height)
            }
            state.committed = r
        case nil:
            break
        }
        redraw()
    }

    fileprivate func mouseUp() {
        state.mouse = NSEvent.mouseLocation
        defer { state.drag = nil; state.dragCurrent = nil; state.updateHover(); redraw() }

        switch state.mode {
        case .area:
            switch state.drag {
            case .selecting:
                if let rect = state.dragRect, rect.width >= 4, rect.height >= 4 {
                    if state.intent == .screenshot {
                        finish(Selection(intent: .screenshot, target: .region(GlobalSpace.fromAppKit(rect))))
                    } else {
                        state.committed = rect
                    }
                } else if let hovered = state.hoveredWindow {
                    // Plain click on a window.
                    if state.intent == .screenshot {
                        finish(Selection(intent: .screenshot, target: .window(hovered.id)))
                    } else {
                        state.committed = hovered.frame.intersection(screenFrame(containing: hovered.frame))
                    }
                }
            case .resizing, .moving:
                if let r = state.committed, r.width < 4 || r.height < 4 { state.committed = nil }
            case nil:
                break
            }
        case .window:
            guard let hovered = state.hoveredWindow else { return }
            if state.intent == .screenshot {
                finish(Selection(intent: .screenshot, target: .window(hovered.id)))
            } else {
                state.selectedWindow = hovered
            }
        case .display:
            guard let screen = state.screenUnderMouse else { return }
            if state.intent == .screenshot {
                finish(Selection(intent: .screenshot, target: .display(GlobalSpace.fromAppKit(screen.frame))))
            } else {
                state.selectedScreen = screen
            }
        }
    }

    fileprivate func mouseMoved() {
        state.mouse = NSEvent.mouseLocation
        state.updateHover()
        redraw()
    }

    fileprivate func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape: clear a pending choice first, then cancel.
            if state.hasChoice {
                state.clearChoice()
                redraw()
            } else {
                finish(nil)
            }
        case 49: // Space toggles area/window
            setMode(state.mode == .window ? .area : .window)
        case 36, 76: // Return / Enter
            confirm()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": setMode(.area)
            case "w": setMode(.window)
            case "f": setMode(.display)
            default: break
            }
        }
    }

    private func screenFrame(containing rect: CGRect) -> CGRect {
        NSScreen.screens.max {
            $0.frame.intersection(rect).width * $0.frame.intersection(rect).height
                < $1.frame.intersection(rect).width * $1.frame.intersection(rect).height
        }?.frame ?? rect
    }
}

// MARK: - State

@MainActor
fileprivate final class OverlayState: ObservableObject {
    enum Drag {
        case selecting(start: CGPoint)
        case moving(offset: CGPoint, size: CGSize)
        case resizing(anchor: CGPoint)
    }

    @Published var intent: SelectionOverlay.Intent
    @Published var mode: SelectionOverlay.Mode
    /// Recording: area chosen and still adjustable (AppKit coordinates).
    @Published var committed: CGRect?
    @Published var selectedWindow: WindowList.Entry?
    @Published var selectedScreen: NSScreen?

    let windows: [WindowList.Entry]
    var mouse: CGPoint = .zero
    var drag: Drag?
    var dragCurrent: CGPoint?
    var hoveredWindow: WindowList.Entry?
    /// Frames of the capture bar (AppKit screen coordinates), excluded from hover.
    var barFrames: [() -> CGRect?] = []

    init(intent: SelectionOverlay.Intent, mode: SelectionOverlay.Mode, windows: [WindowList.Entry]) {
        self.intent = intent
        self.mode = mode
        self.windows = windows
    }

    var screenUnderMouse: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    var dragRect: CGRect? {
        guard case .selecting(let a) = drag, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var isSelecting: Bool {
        guard let r = dragRect else { return false }
        return r.width >= 4 || r.height >= 4
    }

    var hasChoice: Bool { committed != nil || selectedWindow != nil || selectedScreen != nil }

    func clearChoice() {
        committed = nil
        selectedWindow = nil
        selectedScreen = nil
    }

    func chosenTarget() -> SelectionOverlay.Target? {
        switch mode {
        case .area: committed.map { .region(GlobalSpace.fromAppKit($0)) }
        case .window: selectedWindow.map { .window($0.id) }
        case .display: selectedScreen.map { .display(GlobalSpace.fromAppKit($0.frame)) }
        }
    }

    func updateHover() {
        let overBar = barFrames.contains { $0()?.contains(mouse) == true }
        let wantsWindows = mode == .window || (mode == .area && committed == nil)
        hoveredWindow = wantsWindows && !isSelecting && drag == nil && !overBar
            ? windows.first { $0.frame.contains(mouse) }
            : nil
    }
}

/// Corner handles of an adjustable selection.
fileprivate enum Handle: CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    static let size: CGFloat = 10

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: CGPoint(x: r.minX, y: r.minY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.minY)
        case .topLeft: CGPoint(x: r.minX, y: r.maxY)
        case .topRight: CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    func opposite(in r: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: Handle.topRight.point(in: r)
        case .bottomRight: Handle.topLeft.point(in: r)
        case .topLeft: Handle.bottomRight.point(in: r)
        case .topRight: Handle.bottomLeft.point(in: r)
        }
    }

    static func hit(_ p: CGPoint, rect: CGRect) -> Handle? {
        allCases.first { h in
            let c = h.point(in: rect)
            return abs(c.x - p.x) <= size && abs(c.y - p.y) <= size
        }
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

// MARK: - Capture bar

private struct CaptureBar: View {
    @ObservedObject var state: OverlayState
    @ObservedObject var settings: Settings
    let allowsIntentSwitch: Bool
    let setMode: (SelectionOverlay.Mode) -> Void
    let setIntent: (SelectionOverlay.Intent) -> Void
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if allowsIntentSwitch {
                Picker("", selection: Binding(get: { state.intent == .recording }, set: { setIntent($0 ? .recording : .screenshot) })) {
                    Image(systemName: "camera").help("Screenshot").tag(false)
                    Image(systemName: "record.circle").help("Record").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Divider().frame(height: 22)
            }

            Picker("", selection: Binding(get: { state.mode }, set: setMode)) {
                Label("Area", systemImage: "rectangle.dashed").tag(SelectionOverlay.Mode.area)
                Label("Window", systemImage: "macwindow").tag(SelectionOverlay.Mode.window)
                Label(NSScreen.screens.count > 1 ? "Display" : "Fullscreen", systemImage: "display")
                    .tag(SelectionOverlay.Mode.display)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if state.intent == .recording {
                Divider().frame(height: 22)
                MicrophoneMenu(settings: settings)
                Toggle(isOn: $settings.recordSystemAudio) {
                    Image(systemName: settings.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .help("System audio")
                Toggle(isOn: $settings.recordShowsCursor) {
                    Image(systemName: "cursorarrow")
                }
                .help("Show cursor")
                Picker("", selection: $settings.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden()
                .fixedSize()

                Button(action: confirm) {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!state.hasChoice)
                .help(hint)
            } else if state.mode == .display {
                Button("Capture", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .help("Capture the display under the pointer (Return)")
            }

            Button(action: cancel) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Cancel (Esc)")
        }
        .toggleStyle(.button)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
    }

    private var hint: String {
        switch state.mode {
        case .area: "Drag to select an area, then Record (Return)"
        case .window: "Click a window, then Record (Return)"
        case .display: "Click a display, then Record (Return)"
        }
    }
}

/// Mic on/off plus input device choice, as one menu button.
private struct MicrophoneMenu: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Menu {
            Button {
                settings.recordMicrophone = false
            } label: {
                if !settings.recordMicrophone { Image(systemName: "checkmark") }
                Text("No Microphone")
            }
            Divider()
            Button {
                settings.recordMicrophoneID = ""
                settings.recordMicrophone = true
            } label: {
                if settings.recordMicrophone && settings.recordMicrophoneID.isEmpty { Image(systemName: "checkmark") }
                Text(Microphones.systemDefault.map { "System Default (\($0.name))" } ?? "System Default")
            }
            ForEach(Microphones.available()) { device in
                Button {
                    settings.recordMicrophoneID = device.id
                    settings.recordMicrophone = true
                } label: {
                    if settings.recordMicrophone && settings.recordMicrophoneID == device.id { Image(systemName: "checkmark") }
                    Text(device.name)
                }
            }
        } label: {
            Image(systemName: settings.recordMicrophone ? "mic.fill" : "mic.slash")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(settings.recordMicrophone ? "Microphone: \(Microphones.name(for: settings.recordMicrophoneID))" : "Microphone off")
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

        switch state.mode {
        case .area:
            if let r = state.isSelecting ? state.dragRect : state.committed {
                drawHole(toLocal(r))
                drawBorder(toLocal(r), width: 1)
                drawSizeLabel(for: toLocal(r))
                if state.committed != nil, !state.isSelecting { drawHandles(toLocal(r)) }
            } else if let hovered = state.hoveredWindow {
                drawHole(toLocal(hovered.frame))
                drawHighlight(toLocal(hovered.frame))
            } else {
                dim(bounds)
                if window.frame.contains(state.mouse) {
                    drawCrosshair(at: CGPoint(x: state.mouse.x - origin.x, y: state.mouse.y - origin.y))
                }
            }
        case .window:
            let target = state.selectedWindow ?? state.hoveredWindow
            if let target {
                drawHole(toLocal(target.frame))
                drawHighlight(toLocal(target.frame))
                if state.selectedWindow != nil { drawBorder(toLocal(target.frame), width: 3) }
            } else {
                dim(bounds)
            }
        case .display:
            let chosen = state.selectedScreen ?? state.screenUnderMouse
            if window.screen == chosen || window.frame == chosen?.frame {
                drawBorder(bounds.insetBy(dx: 2, dy: 2), width: state.selectedScreen != nil ? 6 : 4)
                drawDisplayLabel()
            } else {
                dim(bounds)
            }
        }

        drawHint()
    }

    // MARK: Drawing helpers

    private var scale: CGFloat { window?.screen?.backingScaleFactor ?? 2 }

    private func dim(_ rect: CGRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        rect.fill()
    }

    private func drawHole(_ hole: CGRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: hole))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()
    }

    private func drawHighlight(_ rect: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        rect.fill()
        drawBorder(rect, width: 1)
    }

    private func drawBorder(_ rect: CGRect, width: CGFloat) {
        let color: NSColor = state.intent == .recording ? .systemRed : .white
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -width / 2, dy: -width / 2))
        path.lineWidth = width
        path.stroke()
    }

    private func drawHandles(_ rect: CGRect) {
        for h in Handle.allCases {
            let c = h.point(in: rect)
            let box = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            NSBezierPath(ovalIn: box).stroke()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        var p = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if p.y + 24 > bounds.maxY { p.y = rect.maxY - 28 }
        drawPill(text, at: p)
    }

    private func drawDisplayLabel() {
        guard let screen = window?.screen else { return }
        let px = "\(Int(screen.frame.width * screen.backingScaleFactor)) × \(Int(screen.frame.height * screen.backingScaleFactor))"
        let action = state.intent == .recording
            ? (state.selectedScreen != nil ? "Selected — press Record" : "Click to select")
            : "Click to capture"
        let text = "\(screen.localizedName) · \(px) · \(action)"
        let size = (text as NSString).size(withAttributes: Self.labelAttributes)
        drawPill(text, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY))
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
        let hint: String = switch (state.mode, state.intent) {
        case (.area, .screenshot): "Drag to select · Click a window · Space: window mode · Return: full display · Esc"
        case (.area, .recording): state.committed == nil
            ? "Drag to select an area · Click a window to use its frame · Esc"
            : "Drag handles to adjust · Return to record · Esc to reselect"
        case (.window, _): "Click a window · Space: area mode · Esc"
        case (.display, _): "Click a display · Esc"
        }
        let size = (hint as NSString).size(withAttributes: Self.labelAttributes)
        drawPill(hint, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 60))
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
