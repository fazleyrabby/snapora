import AppKit
import OSLog

enum CaptureAction {
    case fullscreen, region, window, previousArea, allInOne, timedFullscreen
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hasScreenPermission = Permissions.hasScreenRecording
    @Published private(set) var isCapturing = false
    @Published private(set) var countdown: Int?
    @Published private(set) var statusMessage: String?

    let settings = Settings.shared
    let quickAccess: QuickAccessController
    private var timerTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.snapora.app", category: "capture")

    init() {
        quickAccess = QuickAccessController(settings: Settings.shared)
        registerHotKeys()
    }

    // MARK: - Permissions

    func requestPermission() {
        hasScreenPermission = Permissions.requestScreenRecording()
        if !hasScreenPermission {
            statusMessage = "Enable Snapora in System Settings → Privacy & Security → Screen Recording, then relaunch."
            Permissions.openScreenRecordingSettings()
        }
    }

    // MARK: - Capture

    func perform(_ action: CaptureAction) {
        guard !isCapturing else { return }
        hasScreenPermission = Permissions.hasScreenRecording
        guard hasScreenPermission else {
            requestPermission()
            return
        }
        if action == .timedFullscreen {
            startTimer()
            return
        }
        isCapturing = true
        statusMessage = nil
        Task {
            defer { isCapturing = false }
            await run(action)
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        countdown = nil
    }

    private func startTimer() {
        cancelTimer()
        let seconds = max(1, settings.timerSeconds)
        timerTask = Task {
            for remaining in stride(from: seconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            timerTask = nil
            perform(.fullscreen)
        }
    }

    private func run(_ action: CaptureAction) async {
        let options = settings.captureOptions
        do {
            let image: CGImage
            switch action {
            case .fullscreen, .timedFullscreen:
                image = try await ScreenCapture.captureMainDisplay(options: options)
            case .previousArea:
                guard let area = settings.previousArea else {
                    statusMessage = "No previous area yet. Capture a region first."
                    return
                }
                image = try await ScreenCapture.capture(region: area, options: options)
            case .region, .window, .allInOne:
                let mode: SelectionOverlay.Mode = switch action {
                case .window: .window
                case .allInOne: .allInOne
                default: .region
                }
                switch await SelectionOverlay.present(mode: mode) {
                case .cancelled:
                    return
                case .region(let rect):
                    settings.previousArea = rect
                    image = try await ScreenCapture.capture(region: rect, options: options)
                case .display(let rect):
                    image = try await ScreenCapture.capture(region: rect, options: options)
                case .window(let id):
                    image = try await ScreenCapture.capture(windowID: id, options: options)
                }
            }
            try handleCapture(image)
        } catch {
            // Error descriptions never include capture content.
            log.error("capture failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Capture failed: \(error.localizedDescription)"
        }
    }

    private func handleCapture(_ image: CGImage, screen: NSScreen? = nil) throws {
        let item = try CaptureStore.shared.add(image, template: settings.fileNameTemplate)
        log.info("captured \(image.width)x\(image.height)")
        switch settings.afterCapture {
        case .quickAccess:
            quickAccess.show(item, on: screen)
        case .saveAndCopy:
            let copied = QuickAccessController.copyToPasteboard(item)
            let saved = try QuickAccessController.copyFile(item, to: settings.saveDirectory)
            statusMessage = copied
                ? "Copied and saved \(saved.lastPathComponent)"
                : "Saved \(saved.lastPathComponent) (copy failed)"
        }
    }

    func reopenLastCapture() {
        guard let item = CaptureStore.shared.lastCapture,
              FileManager.default.fileExists(atPath: item.url.path) else {
            statusMessage = "No recent capture to reopen."
            return
        }
        quickAccess.show(item)
    }

    // MARK: - Shortcuts

    private func registerHotKeys() {
        let bindings: [(HotKeyCenter.Shortcut, CaptureAction)] = [
            (.allInOne, .allInOne),
            (.window, .window),
            (.fullscreen, .fullscreen),
            (.region, .region),
            (.previousArea, .previousArea),
        ]
        var conflicts: [String] = []
        for (shortcut, action) in bindings {
            do {
                try HotKeyCenter.shared.register(shortcut) { [weak self] in self?.perform(action) }
            } catch {
                conflicts.append(shortcut.display)
            }
        }
        if !conflicts.isEmpty {
            statusMessage = "Shortcuts unavailable (in use by another app): \(conflicts.joined(separator: ", "))"
        }
    }
}
