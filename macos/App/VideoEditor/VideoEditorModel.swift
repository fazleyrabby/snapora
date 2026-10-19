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

    enum Format: String, CaseIterable, Identifiable {
        case mp4 = "MP4", gif = "GIF"
        var id: String { rawValue }
    }
    enum DimensionMode: String, CaseIterable, Identifiable {
        case original, p1080, p720, p480, half, custom
        var id: String { rawValue }
        var shortSide: CGFloat? {
            switch self {
            case .p1080: 1080
            case .p720: 720
            case .p480: 480
            default: nil
            }
        }
    }

    @Published var format: Format = .mp4
    @Published var quality: VideoQuality = .high
    @Published var audioMode: AudioMode = .keep
    @Published var volume = 1.0
    @Published var gifFPS = 15
    @Published var dimensionMode: DimensionMode = .original
    @Published private var customWidth = 0
    @Published private(set) var audioChannels: Int?

    /// Called after a successful export (the window closes itself).
    var onFinished: (() -> Void)?
    var onCancel: (() -> Void)?

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
            crop: crop, audio: hasAudio ? audioMode : .keep, volume: volume,
            quality: quality, outputSize: outputSize
        )
    }

    // MARK: - Dimensions

    /// Even-sized pixel size of the (cropped) source, before scaling.
    var baseSize: CGSize {
        let s = crop.map { CropMath.encodable($0, bounds: bounds).size } ?? displaySize
        return VideoExporter.evenSize(s)
    }

    /// Final encoded size for the chosen dimension option.
    var outputSize: CGSize {
        let base = baseSize
        func scaled(_ f: CGFloat) -> CGSize {
            VideoExporter.evenSize(CGSize(width: base.width * f, height: base.height * f))
        }
        switch dimensionMode {
        case .original: return base
        case .half: return scaled(0.5)
        case .p1080, .p480, .p720:
            let target = dimensionMode.shortSide ?? 0
            let short = min(base.width, base.height)
            return short <= target ? base : scaled(target / short)
        case .custom:
            let w = CGFloat(max(2, customWidth > 0 ? customWidth : Int(base.width)))
            return VideoExporter.evenSize(CGSize(width: w, height: w * base.height / base.width))
        }
    }

    var outputWidth: Int {
        get { Int(outputSize.width) }
        set {
            guard dimensionMode == .custom else { return }
            customWidth = min(8192, max(2, newValue))
        }
    }

    var outputHeight: Int {
        get { Int(outputSize.height) }
        set {
            guard dimensionMode == .custom else { return }
            let b = baseSize
            outputWidth = Int((CGFloat(newValue) * b.width / b.height).rounded())
        }
    }

    func setDimensionMode(_ mode: DimensionMode) {
        if mode == .custom, dimensionMode != .custom { customWidth = Int(outputSize.width) }
        dimensionMode = mode
    }

    func dimensionTitle(_ mode: DimensionMode) -> String {
        switch mode {
        case .original: "Original (\(Int(baseSize.width)) × \(Int(baseSize.height)))"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .half: "50%"
        case .custom: "Custom"
        }
    }

    // MARK: - Estimate

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }

    var estimatedBytes: Double {
        switch format {
        case .mp4:
            let ch: Int? = (hasAudio && audioMode != .mute) ? (audioMode == .mono ? 1 : min(2, audioChannels ?? 2)) : nil
            return SizeEstimate.mp4Bytes(quality: quality, size: outputSize, fps: frameRate,
                                         audioChannels: ch, duration: trimmedDuration)
        case .gif:
            return SizeEstimate.gifBytes(size: outputSize, fps: gifFPS, duration: trimmedDuration)
        }
    }

    var estimatedSizeText: String {
        let mb = estimatedBytes / 1_000_000
        return mb < 0.1 ? "~\(Int((estimatedBytes / 1000).rounded())) KB"
            : String(format: "~%.1f MB", mb)
    }
    var frameStep: Double { 1.0 / max(1, frameRate) }

    // MARK: - Loading

    func load() async {
        do {
            let (_, geo) = try await VideoGeometry.load(from: asset)
            let dur = try await asset.load(.duration).seconds
            hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            audioChannels = await VideoExporter.sourceAudioChannels(of: asset)
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

    func convert() {
        guard isReady, !isExporting else { return }
        pause(at: nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        panel.nameFieldStringValue = baseName + (format == .mp4 ? " edited.mp4" : " edited.gif")
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let edit = self.edit
        let asset = self.asset
        switch format {
        case .mp4:
            beginExport(label: "Exporting MP4…", dest: dest) { progress in
                try await VideoExporter.export(asset: asset, edit: edit, to: dest, progress: progress)
                return true
            }
        case .gif:
            let range = edit.trim
            let crop = self.crop.map { CropMath.encodable($0, bounds: bounds) }
            let options = GIFOptions(fps: gifFPS, maxWidth: Int(outputSize.width))
            beginExport(label: "Exporting GIF…", dest: dest) { [weak self] progress in
                let info = try await GIFExporter.export(
                    asset: asset, timeRange: range, crop: crop, options: options, to: dest, progress: progress
                )
                if info.reduced {
                    await MainActor.run {
                        self?.errorMessage = String(format: "GIF saved. The frame rate was lowered from %d to %.1f fps to keep the clip under %d frames.",
                                                    info.requestedFPS, info.effectiveFPS, GIFExporter.maxFrames)
                    }
                    return false
                }
                return true
            }
        }
    }

    private func beginExport(
        label: String, dest: URL,
        work: @escaping (@escaping (Double) -> Void) async throws -> Bool
    ) {
        exportLabel = label
        exportProgress = 0
        exportTask = Task { [weak self] in
            do {
                let close = try await work { p in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportProgress != nil else { return }
                        self.exportProgress = p
                    }
                }
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                if close { self?.exportProgress = nil; self?.onFinished?() }
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
