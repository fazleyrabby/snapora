import AppKit
import AVFoundation
import Combine

/// Playback + edit state for one editor window. Playback (AVPlayer), edit
/// decisions (trim/crop/mute) and export (VideoExporter/GIFExporter) are kept
/// separate; nothing is re-encoded until the user exports.
@MainActor
final class VideoEditorModel: ObservableObject {
    static let minTrimDuration = 0.1

    let url: URL
    let asset: AVURLAsset
    let player = AVPlayer()

    @Published private(set) var isReady = false
    @Published private(set) var duration = 0.0
    @Published private(set) var displaySize = CGSize(width: 16, height: 9)
    @Published private(set) var frameRate = 30.0
    @Published private(set) var hasAudio = false
    @Published private(set) var thumbnails: [CGImage?] = []

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var trimStart = 0.0
    @Published private(set) var trimEnd = 0.0

    @Published var cropMode = false
    @Published var crop: CGRect?
    @Published var aspect: CropAspect = .free
    @Published var muteAudio = false

    @Published var gifFPS = 15
    @Published var gifMaxWidth = 640   // 0 = original

    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportLabel = ""
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: displaySize) }
    var edit: VideoEdit {
        VideoEdit(
            trim: CMTimeRange(start: Self.time(trimStart), end: Self.time(trimEnd)),
            crop: crop, muteAudio: muteAudio
        )
    }
    var frameStep: Double { 1.0 / max(1, frameRate) }

    // MARK: - Loading

    func load() async {
        do {
            let (_, geo) = try await VideoGeometry.load(from: asset)
            let dur = try await asset.load(.duration).seconds
            hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            guard dur.isFinite, dur > 0 else { throw VideoEditError.noVideoTrack }
            duration = dur
            trimEnd = dur
            displaySize = geo.displaySize
            frameRate = geo.frameRate > 0 ? Double(geo.frameRate) : 30
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            applyPlaybackRange()
            observePlayer()
            isReady = true
            generateThumbnails()
        } catch {
            errorMessage = "Could not open the video: \(error.localizedDescription)"
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = t.seconds
                if t.seconds >= self.trimEnd - 0.001 { self.pause(at: self.trimEnd) }
            }
        }
        statusCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status != .paused
            }
    }

    /// Lazily builds ~14 small thumbnails; one decoded at a time.
    private func generateThumbnails() {
        let count = 14
        let dur = duration
        let asset = self.asset
        thumbnails = Array(repeating: nil, count: count)
        thumbTask = Task {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 240)
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            let times = (0..<count).map {
                CMTime(seconds: dur * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)
            }
            var index = 0
            for await result in gen.images(for: times) {
                if Task.isCancelled { return }
                if let image = try? result.image, index < count {
                    thumbnails[index] = image
                }
                index += 1
            }
        }
    }

    func shutdown() {
        exportTask?.cancel()
        thumbTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusCancellable = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Playback

    func togglePlay() {
        guard isReady else { return }
        if isPlaying { pause(at: nil); return }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart { seek(to: trimStart) }
        player.play()
    }

    func pause(at time: Double?) {
        player.pause()
        if let time { seek(to: time) }
    }

    func seek(to seconds: Double) {
        let t = min(max(seconds, trimStart), trimEnd)
        currentTime = t
        player.seek(to: Self.time(t), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        if isPlaying { player.pause() }
        seek(to: currentTime + Double(frames) * frameStep)
    }

    // MARK: - Trim

    func setTrimStart(_ t: Double) {
        trimStart = min(max(0, t), trimEnd - Self.minTrimDuration)
        applyPlaybackRange()
        seek(to: trimStart)
    }

    func setTrimEnd(_ t: Double) {
        trimEnd = max(min(duration, t), trimStart + Self.minTrimDuration)
        applyPlaybackRange()
        seek(to: trimEnd)
    }

    private func applyPlaybackRange() {
        player.currentItem?.forwardPlaybackEndTime = Self.time(trimEnd)
    }

    // MARK: - Crop

    func setCropMode(_ on: Bool) {
        cropMode = on
        if on, crop == nil {
            crop = CropMath.defaultRect(aspect: aspect.ratio, bounds: bounds)
        }
    }

    func setAspect(_ a: CropAspect) {
        aspect = a
        if let crop { self.crop = CropMath.constrain(rect: crop, aspect: a.ratio, bounds: bounds) }
    }

    func clearCrop() {
        crop = nil
        cropMode = false
    }

    // MARK: - Export

    var isExporting: Bool { exportProgress != nil }

    func cancelExport() { exportTask?.cancel() }

    func exportMP4() {
        guard isReady, !isExporting else { return }
        pause(at: nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = baseName + " edited.mp4"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let edit = self.edit
        let asset = self.asset
        beginExport(label: "Exporting MP4…", dest: dest) { progress in
            try await VideoExporter.export(asset: asset, edit: edit, to: dest, progress: progress)
        }
    }

    func exportGIF() {
        guard isReady, !isExporting else { return }
        pause(at: nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = baseName + ".gif"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let range = edit.trim
        let crop = self.crop.map { CropMath.encodable($0, bounds: bounds) }
        let options = GIFOptions(fps: gifFPS, maxWidth: gifMaxWidth == 0 ? nil : gifMaxWidth)
        let asset = self.asset
        beginExport(label: "Exporting GIF…", dest: dest) { progress in
            try await GIFExporter.export(
                asset: asset, timeRange: range, crop: crop, options: options, to: dest, progress: progress
            )
        }
    }

    private func beginExport(
        label: String, dest: URL,
        work: @escaping (@escaping (Double) -> Void) async throws -> Void
    ) {
        exportLabel = label
        exportProgress = 0
        exportTask = Task { [weak self] in
            do {
                try await work { p in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportProgress != nil else { return }
                        self.exportProgress = p
                    }
                }
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch is CancellationError {
                // User cancelled; partial output already removed.
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.exportProgress = nil
            self?.exportTask = nil
        }
    }

    private var baseName: String { url.deletingPathExtension().lastPathComponent }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
