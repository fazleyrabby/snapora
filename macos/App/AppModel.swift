import AppKit
import AVFoundation
import OSLog

enum CaptureAction {
    case fullscreen, region, window, previousArea, allInOne, timedFullscreen, recording, ocr, scrolling
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
        quickAccess.onEdit = { item in
            switch item.kind {
            case .image: ImageEditor.open(url: item.url)
            case .video: VideoEditor.open(url: item.url)
            }
        }
        HistoryWindow.onOpenImage = { ImageEditor.open(url: $0) }
        ImageEditor.onDone = { [weak self] source, edited, size in
            let item = CaptureStore.shared.addImage(url: edited, pixelSize: size)
            HistoryService.shared.recordScreenshot(url: edited, pixelSize: size)
            self?.quickAccess.show(item, replacing: source)
        }
        registerHotKeys()
        #if DEBUG
        ReadmeShots.runIfRequested(quickAccess: quickAccess)
        #endif
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
            if action == .scrolling {
                try await scrollingCapture()
                return
            }
            let image: CGImage
            switch action {
            case .recording, .ocr, .scrolling:
                return
            case .fullscreen where NSScreen.screens.count > 1:
                // Several displays: let the user pick one.
                guard let selection = await SelectionOverlay.present(intent: .screenshot, mode: .display) else { return }
                try await handle(selection)
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
                let mode: SelectionOverlay.Mode = action == .window ? .window : .area
                let overlayOptions = SelectionOverlay.Options(allowsIntentSwitch: action == .allInOne)
                guard let selection = await SelectionOverlay.present(intent: .screenshot, mode: mode, options: overlayOptions)
                else { return }
                try await handle(selection)
                return
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
        case .openEditor:
            ImageEditor.open(url: item.url)
        case .saveAndCopy:
            let copied = QuickAccessController.copyToPasteboard(item)
            let saved = try QuickAccessController.copyFile(item, to: settings.saveDirectory)
            statusMessage = copied
                ? "Copied and saved \(saved.lastPathComponent)"
                : "Saved \(saved.lastPathComponent) (copy failed)"
        }
    }

    private func startRecording() async throws {
        guard let selection = await SelectionOverlay.present(intent: .recording, mode: .area) else { return }
        try await handle(selection)
    }

    /// Captures or records whatever the overlay returned.
    private func handle(_ selection: SelectionOverlay.Selection) async throws {
        let options = settings.captureOptions
        switch selection.intent {
        case .screenshot:
            let image: CGImage
            switch selection.target {
            case .region(let rect):
                settings.previousArea = rect
                image = try await ScreenCapture.capture(region: rect, options: options)
            case .display(let rect):
                image = try await ScreenCapture.capture(region: rect, options: options)
            case .window(let id):
                image = try await ScreenCapture.capture(windowID: id, options: options)
            }
            try handleCapture(image)
        case .recording:
            let source: RecordingConfig.Source
            switch selection.target {
            case .region(let rect):
                settings.previousArea = rect
                source = .region(rect)
            case .display(let rect): source = .region(rect)
            case .window(let id): source = .window(id)
            }
            isCapturing = false
            await recording.start(config: settings.recordingConfig(source: source), template: settings.fileNameTemplate)
        }
    }

    private func scrollingCapture() async throws {
        guard let selection = await SelectionOverlay.present(intent: .screenshot, mode: .area, options: .init(showsBar: false)),
              case .region(let rect) = selection.target else { return }
        guard let result = try await ScrollingCapture.run(region: rect, options: settings.captureOptions) else { return }
        try handleCapture(result.image)
        if result.uncertainJoins > 0 {
            statusMessage = "Scrolling capture saved; \(result.uncertainJoins) join(s) may be inaccurate — please check."
        }
    }

    private func recognizeText() async throws {
        guard let selection = await SelectionOverlay.present(intent: .screenshot, mode: .area, options: .init(showsBar: false)),
              case .region(let rect) = selection.target else { return }
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
            let item = CaptureStore.shared.addVideo(url: url, pixelSize: size, duration: duration.isFinite ? duration : 0)
            switch settings.afterRecording {
            case .quickAccess:
                quickAccess.show(item)
            case .openEditor:
                VideoEditor.open(url: url)
            case .saveToFolder:
                do {
                    let saved = try QuickAccessController.copyFile(item, to: settings.saveDirectory)
                    statusMessage = "Saved \(saved.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                } catch {
                    statusMessage = "Recording saved in Snapora's library; copy failed: \(error.localizedDescription)"
                }
            }
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
