import AppKit
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hasScreenPermission = Permissions.hasScreenRecording
    @Published private(set) var isCapturing = false
    @Published private(set) var statusMessage: String?

    private let log = Logger(subsystem: "com.snapora.app", category: "capture")

    func requestPermission() {
        hasScreenPermission = Permissions.requestScreenRecording()
        if !hasScreenPermission {
            statusMessage = "Enable Snapora in System Settings → Privacy & Security → Screen Recording, then relaunch."
            Permissions.openScreenRecordingSettings()
        }
    }

    func captureFullscreen() {
        hasScreenPermission = Permissions.hasScreenRecording
        guard hasScreenPermission else {
            requestPermission()
            return
        }
        isCapturing = true
        statusMessage = nil
        Task {
            defer { isCapturing = false }
            do {
                let image = try await ScreenCapture.captureMainDisplay()
                let url = try ImageExporter.savePNG(image, to: ImageExporter.defaultDirectory)
                log.info("saved fullscreen capture \(image.width)x\(image.height)")
                statusMessage = "Saved \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                // Error descriptions never include capture content.
                log.error("fullscreen capture failed: \(error.localizedDescription, privacy: .public)")
                statusMessage = "Capture failed: \(error.localizedDescription)"
            }
        }
    }
}
