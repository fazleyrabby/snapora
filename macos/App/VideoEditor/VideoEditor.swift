import AppKit
import SwiftUI

/// Entry point for the minimal video editor (Milestone 5).
@MainActor
enum VideoEditor {
    private static var controllers: [URL: VideoEditorWindowController] = [:]

    /// Opens an editor window for the MP4 at `url`, or focuses the existing one.
    static func open(url: URL) {
        let key = url.standardizedFileURL
        if let existing = controllers[key] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = VideoEditorWindowController(url: key) {
            controllers[key] = nil
        }
        controllers[key] = controller
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let model: VideoEditorModel
    private let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        self.onClose = onClose
        model = VideoEditorModel(url: url)
        let host = NSHostingController(rootView: VideoEditorView(model: model))
        window = NSWindow(contentViewController: host)
        super.init()
        window.title = url.lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 680))
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        model.shutdown()
        window.delegate = nil
        onClose()
    }
}
