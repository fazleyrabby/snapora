import AppKit
import SwiftUI

/// Entry point: `ImageEditor.open(url:)` opens (or focuses) an editor window.
@MainActor
enum ImageEditor {
    private static var editors: [URL: ImageImageEditorWindowController] = [:]

    /// Called after Done saved the edited image: (source, edited file, pixel size).
    static var onDone: ((URL, URL, CGSize) -> Void)?

    #if DEBUG
    /// Debug-only: pre-populates new editors (README screenshots).
    static var debugSeed: ((EditorModel) -> Void)?
    #endif

    static func open(url: URL) {
        let key = url.standardizedFileURL
        if let existing = editors[key] {
            existing.show()
            return
        }
        guard let image = loadImage(url) else {
            let alert = NSAlert()
            alert.messageText = "Cannot open image"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        let controller = ImageImageEditorWindowController(url: url, image: image) { editors[key] = nil }
        editors[key] = controller
        controller.show()
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

final class EditorNSWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ImageImageEditorWindowController: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private let window: EditorNSWindow
    private let onClosed: () -> Void
    private var closed = false

    init(url: URL, image: CGImage, onClosed: @escaping () -> Void) {
        self.model = EditorModel(url: url, source: image)
        self.onClosed = onClosed
        #if DEBUG
        ImageEditor.debugSeed?(model)
        #endif

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let w = min(max(CGFloat(image.width) / backing + 60, 900), screen.width * 0.9)
        let h = min(max(CGFloat(image.height) / backing + 160, 640), screen.height * 0.9)
        window = EditorNSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        super.init()

        window.title = url.lastPathComponent
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: EditorRootView(model: model))
        window.setContentSize(NSSize(width: w, height: h))
        window.center()
        window.delegate = self
        window.keyHandler = { [weak self] event in
            guard let self else { return false }
            return self.model.handleKeyEquivalent(event, textEditing: self.window.firstResponder is NSText)
        }
        model.onClose = { [weak self] in self?.window.close() }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let canvas = model.canvas { window.makeFirstResponder(canvas) }
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        model.onClose = nil
        window.contentViewController = nil
        onClosed()
    }
}
