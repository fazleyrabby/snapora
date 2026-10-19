import AppKit
import AVFoundation
import OSLog

enum CaptureAction {
    case fullscreen, region, window, previousArea, allInOne, timedFullscreen, recording, ocr
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hasScreenPermission = Permissions.hasScreenRecording
    @Published private(set) var isCapturing = false
    @Published private(set) var countdown: Int?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastRecording: URL?

    let settings = Settings.shared
    let quickAccess: QuickAccessController
    let recording = RecordingController()
    private var timerTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.snapora.app", category: "capture")

    init() {
        quickAccess = QuickAccessController(settings: Settings.shared)
        _ = HistoryService.shared // runs pruning and retention at launch
        quickAccess.onPin = { PinnedImage.pin(url: $0.url) }
        quickAccess.onEdit = { ImageEditor.open(url: $0.url) }
        HistoryWindow.onOpenImage = { ImageEditor.open(url: $0) }
        registerHotKeys()
        recording.onFinished = { [weak self] url in self?.handleRecording(url) }
        recording.onError = { [weak self] message in self?.statusMessage = message }
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
        if action == .recording, recording.isActive {
            Task { await recording.stop() }
            return
        }
        guard !isCapturing, !recording.isActive else { return }
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
            if action == .recording {
                try await startRecording()
                return
            }
            if action == .ocr {
                try await recognizeText()
                return
            }
            let image: CGImage
            switch action {
            case .recording, .ocr:
                return
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
        HistoryService.shared.recordScreenshot(url: item.url, pixelSize: item.pixelSize)
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

    private func startRecording() async throws {
        let source: RecordingConfig.Source
        switch await SelectionOverlay.present(mode: .allInOne) {
        case .cancelled: return
        case .region(let rect):
            settings.previousArea = rect
            source = .region(rect)
        case .display(let rect): source = .region(rect)
        case .window(let id): source = .window(id)
        }
        isCapturing = false
        await recording.start(config: settings.recordingConfig(source: source), template: settings.fileNameTemplate)
    }

    private func recognizeText() async throws {
        guard case .region(let rect) = await SelectionOverlay.present(mode: .region) else { return }
        let image = try await ScreenCapture.capture(region: rect, options: settings.captureOptions)
        let text = try await TextRecognizer.recognize(image)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.split(separator: "\n").count
        statusMessage = "Copied \(lines) line\(lines == 1 ? "" : "s") of text"
    }

    func editLastRecording() {
        guard let url = lastRecording, FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "No recent recording."
            return
        }
        VideoEditor.open(url: url)
    }

    private func handleRecording(_ url: URL) {
        lastRecording = url
        Task {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            var size = CGSize.zero
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                size = (try? await track.load(.naturalSize)) ?? .zero
            }
            HistoryService.shared.recordVideo(url: url, kind: .recording, pixelSize: size, duration: duration)
        }
        do {
            let saved = try QuickAccessController.copyFile(
                CaptureItem(id: UUID(), url: url, pixelSize: .zero, createdAt: Date()),
                to: settings.saveDirectory
            )
            statusMessage = "Saved \(saved.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        } catch {
            statusMessage = "Recording saved in Snapora's library; copy failed: \(error.localizedDescription)"
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
            (.recording, .recording),
            (.ocr, .ocr),
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
