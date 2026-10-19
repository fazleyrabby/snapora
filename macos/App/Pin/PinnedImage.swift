import AppKit
import UniformTypeIdentifiers

@MainActor
enum PinnedImage {
    private static var panels: [PinPanel] = []
    private static let framesKey = "pinnedImageFrames"

    static func pin(url: URL) {
        guard let image = NSImage(contentsOf: url) else { NSSound.beep(); return }
        let rep = image.representations.first
        let pxW = CGFloat(rep?.pixelsWide ?? 0) > 0 ? CGFloat(rep!.pixelsWide) : image.size.width
        let pxH = CGFloat(rep?.pixelsHigh ?? 0) > 0 ? CGFloat(rep!.pixelsHigh) : image.size.height
        guard pxW > 0, pxH > 0 else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        var size = CGSize(width: pxW / scale, height: pxH / scale)
        let vis = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, vis.width * 0.8 / size.width, vis.height * 0.8 / size.height)
        size = CGSize(width: max(40, (size.width * fit).rounded()), height: max(40, (size.height * fit).rounded()))

        var frame = CGRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height)
        if let saved = savedFrame(for: url), NSScreen.screens.contains(where: { $0.frame.intersects(saved) }),
           abs(saved.width / saved.height - size.width / size.height) < 0.02 {
            frame = saved
        } else if !panels.isEmpty {
            frame.origin.x += CGFloat(panels.count % 8) * 24
            frame.origin.y -= CGFloat(panels.count % 8) * 24
        }

        let panel = PinPanel(url: url, image: image, baseSize: size, frame: frame)
        panels.append(panel)
        panel.onClose = { [weak panel] in
            guard let panel else { return }
            PinnedImage.saveFrame(panel.frame, for: panel.url)
            PinnedImage.panels.removeAll { $0 === panel }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    static func closeAll() {
        for p in panels { p.close() }
        panels.removeAll()
    }

    static func unlockAll() { for p in panels { p.setLocked(false) } }
    static var hasLockedPins: Bool { panels.contains { $0.ignoresMouseEvents } }
    static var count: Int { panels.count }

    private static func savedFrame(for url: URL) -> CGRect? {
        guard let d = UserDefaults.standard.dictionary(forKey: framesKey) as? [String: String],
              let s = d[url.path] else { return nil }
        let r = NSRectFromString(s)
        return r.width > 0 && r.height > 0 ? r : nil
    }

    fileprivate static func saveFrame(_ frame: CGRect, for url: URL) {
        var d = (UserDefaults.standard.dictionary(forKey: framesKey) as? [String: String]) ?? [:]
        d[url.path] = NSStringFromRect(frame)
        if d.count > 100 { d = Dictionary(uniqueKeysWithValues: Array(d.prefix(50))) }
        UserDefaults.standard.set(d, forKey: framesKey)
    }
}

@MainActor
private final class PinPanel: NSPanel {
    let url: URL
    let baseSize: CGSize
    var onClose: (() -> Void)?
    private var zoomLevel: CGFloat = 1

    init(url: URL, image: NSImage, baseSize: CGSize, frame: CGRect) {
        self.url = url
        self.baseSize = baseSize
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentAspectRatio = baseSize
        minSize = CGSize(width: baseSize.width * 0.1, height: baseSize.height * 0.1)
        maxSize = CGSize(width: baseSize.width * 4, height: baseSize.height * 4)
        zoomLevel = frame.width / baseSize.width

        let view = PinContentView(image: image)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        view.owner = self
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        onClose?()
        onClose = nil
        super.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return } // Escape
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }

    func zoom(by factor: CGFloat) {
        zoomLevel = min(4, max(0.1, frame.width / baseSize.width * factor))
        let newSize = CGSize(width: baseSize.width * zoomLevel, height: baseSize.height * zoomLevel)
        let c = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(CGRect(x: c.x - newSize.width / 2, y: c.y - newSize.height / 2,
                        width: newSize.width, height: newSize.height), display: true)
    }

    func setLocked(_ locked: Bool) {
        ignoresMouseEvents = locked
        alphaValue = locked ? alphaValue : alphaValue
        contentView?.needsDisplay = true
    }

    // Menu actions
    func copyImage() {
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        pb.setData(data, forType: .png)
    }

    func saveAs() {
        let sp = NSSavePanel()
        sp.nameFieldStringValue = url.lastPathComponent
        sp.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .png]
        sp.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        if sp.runModal() == .OK, let dest = sp.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    func resetSize() {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(CGRect(x: c.x - baseSize.width / 2, y: c.y - baseSize.height / 2,
                        width: baseSize.width, height: baseSize.height), display: true)
    }
}

@MainActor
private final class PinContentView: NSView {
    weak var owner: PinPanel?
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        owner?.zoom(by: exp(dy * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)))
    }

    override func magnify(with event: NSEvent) {
        owner?.zoom(by: 1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.close() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let m = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void, on: Bool = false) {
            let it = ClosureItem(title: title, action: action)
            it.state = on ? .on : .off
            m.addItem(it)
        }
        add("Copy", { owner.copyImage() })
        add("Save As…", { owner.saveAs() })
        m.addItem(.separator())
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pct in [100, 75, 50, 25] {
            let it = ClosureItem(title: "\(pct)%") { owner.alphaValue = CGFloat(pct) / 100 }
            it.state = abs(owner.alphaValue - CGFloat(pct) / 100) < 0.01 ? .on : .off
            sub.addItem(it)
        }
        op.submenu = sub
        m.addItem(op)
        add("Actual Size", { owner.resetSize() })
        add("Lock (Click-Through)", { owner.setLocked(true) })
        m.addItem(.separator())
        add("Close", { owner.close() })
        return m
    }
}

@MainActor
private final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
