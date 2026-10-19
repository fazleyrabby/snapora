import AppKit
import SwiftUI

/// Observable state for one card in the stack.
@MainActor
final class QuickAccessCard: ObservableObject, Identifiable {
    let item: CaptureItem
    let image: NSImage?
    @Published var hovering = false
    @Published var toast: String?
    var elapsed: TimeInterval = 0
    private var toastTask: Task<Void, Never>?

    nonisolated let id: UUID

    init(item: CaptureItem) {
        self.item = item
        self.id = item.id
        self.image = NSImage(contentsOf: item.url)
    }

    /// Thumbnail size in points: fits within 240x180 preserving aspect ratio.
    var displaySize: CGSize {
        let w = max(item.pixelSize.width, 1), h = max(item.pixelSize.height, 1)
        let scale = min(QuickAccessMetrics.maxWidth / w, QuickAccessMetrics.maxHeight / h)
        return CGSize(width: max((w * scale).rounded(), 60), height: max((h * scale).rounded(), 40))
    }

    func flash(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}

enum QuickAccessMetrics {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 180
    static let spacing: CGFloat = 10
    static let margin: CGFloat = 16
    /// Room around the stack so card shadows are not clipped.
    static let shadowPad: CGFloat = 14
    static let maxVisible = 5
}

@MainActor
final class QuickAccessModel: ObservableObject {
    /// Oldest first; the newest card is last, so it renders at the bottom.
    @Published var cards: [QuickAccessCard] = []
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickAccessController {
    let settings: Settings
    private let model = QuickAccessModel()
    private var panel: NSPanel?
    private var timer: Timer?

    /// Called when the user presses Edit. Defaults to opening the file.
    var onEdit: (CaptureItem) -> Void = { item in NSWorkspace.shared.open(item.url) }
    /// Called when the user presses Pin. The button is hidden when nil.
    var onPin: ((CaptureItem) -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Showing

    func show(_ item: CaptureItem, on screen: NSScreen? = nil) {
        if let existing = model.cards.firstIndex(where: { $0.id == item.id }) {
            model.cards[existing].elapsed = 0
            presentPanel(on: screen)
            return
        }
        model.cards.append(QuickAccessCard(item: item))
        while model.cards.count > QuickAccessMetrics.maxVisible {
            model.cards.removeFirst()
        }
        presentPanel(on: screen)
    }

    private func presentPanel(on screen: NSScreen?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let target = screen ?? Self.screenWithMouse()
        layout(panel, on: target)
        panel.orderFrontRegardless()
        startTimer()
    }

    private func makePanel() -> NSPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let view = QuickAccessStackView(
            model: model,
            actions: QuickAccessActions(
                copy: { [weak self] in self?.copy($0) },
                save: { [weak self] in self?.save($0) },
                edit: { [weak self] in self?.onEdit($0.item) },
                pin: { [weak self] card in self?.onPin?(card.item) },
                hasPin: { [weak self] in self?.onPin != nil },
                close: { [weak self] in self?.dismiss($0) }
            )
        )
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func layout(_ panel: NSPanel, on screen: NSScreen?) {
        let pad = QuickAccessMetrics.shadowPad
        let cards = model.cards
        let height = cards.reduce(0) { $0 + $1.displaySize.height }
            + QuickAccessMetrics.spacing * CGFloat(max(cards.count - 1, 0))
        let size = NSSize(
            width: QuickAccessMetrics.maxWidth + pad * 2,
            height: height + pad * 2
        )
        let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: visible.minX + QuickAccessMetrics.margin - pad,
            y: visible.minY + QuickAccessMetrics.margin - pad
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Dismissing

    func dismiss(_ card: QuickAccessCard) {
        model.cards.removeAll { $0.id == card.id }
        if model.cards.isEmpty {
            panel?.orderOut(nil)
            timer?.invalidate()
            timer = nil
        } else if let panel {
            layout(panel, on: panel.screen)
        }
    }

    // MARK: - Auto close

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let limit = TimeInterval(settings.quickAccessAutoCloseSeconds)
        guard limit > 0 else { return }
        for card in model.cards where !card.hovering {
            card.elapsed += 0.25
            if card.elapsed >= limit { dismiss(card) }
        }
    }

    // MARK: - Actions

    private func copy(_ card: QuickAccessCard) {
        if Self.copyToPasteboard(card.item) {
            card.flash("Copied")
        } else {
            card.flash("Copy failed")
        }
    }

    private func save(_ card: QuickAccessCard) {
        do {
            let url = try Self.copyFile(card.item, to: settings.saveDirectory)
            card.flash("Saved")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            card.flash("Save failed")
        }
    }

    // MARK: - Shared helpers (also used by AppModel)

    @discardableResult
    static func copyToPasteboard(_ item: CaptureItem) -> Bool {
        guard let data = try? Data(contentsOf: item.url), let image = NSImage(data: data) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        pb.setData(data, forType: .png)
        return true
    }

    /// Copies the capture file into `directory` with a unique name.
    static func copyFile(_ item: CaptureItem, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = ImageExporter.uniqueURL(in: directory, fileName: item.url.lastPathComponent)
        try FileManager.default.copyItem(at: item.url, to: target)
        return target
    }
}
