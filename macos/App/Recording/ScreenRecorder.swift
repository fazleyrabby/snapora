import AVFoundation
import CoreMedia
import OSLog
import ScreenCaptureKit

struct RecordingConfig {
    enum Source {
        /// Global capture-space rect (top-left origin).
        case region(CGRect)
        case window(CGWindowID)
    }

    enum Codec { case h264, hevc }

    var source: Source
    var framesPerSecond = 60
    var showsCursor = true
    var systemAudio = false
    var microphone = false
    var codec: Codec = .h264
    var hideDesktopIcons = false
}

enum RecordingError: LocalizedError {
    case noDisplay
    case windowNotFound
    case writerFailed(String)
    case microphoneDenied
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available to record."
        case .windowNotFound: "The selected window is no longer available."
        case .writerFailed(let m): "Could not write the recording: \(m)"
        case .microphoneDenied: "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .emptyRecording: "The recording contains no frames."
        }
    }
}

/// Records a display region or window to MP4 with ScreenCaptureKit and
/// AVAssetWriter (VideoToolbox hardware encoding).
///
/// Threading: all sample handling and writer access happen on `queue`.
/// Public methods are called from the main actor.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    let outputURL: URL
    private let config: RecordingConfig
    private let queue = DispatchQueue(label: "com.snapora.recorder", qos: .userInteractive)
    private let log = Logger(subsystem: "com.snapora.app", category: "recording")

    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private let timeline = RecordingTimeline()
    private var sessionStarted = false
    private var droppedFrames = 0
    private var writtenFrames = 0
    private var streamError: Error?

    /// Called on the main queue if the stream stops unexpectedly.
    var onUnexpectedStop: ((Error) -> Void)?

    init(config: RecordingConfig, outputURL: URL) {
        self.config = config
        self.outputURL = outputURL
    }

    // MARK: - Control

    func start() async throws {
        if config.microphone, !(await Self.requestMicrophoneAccess()) {
            throw RecordingError.microphoneDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, streamConfig) = try makeStreamConfiguration(content: content)
        try makeWriter(width: streamConfig.width, height: streamConfig.height)

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if config.microphone {
            if #available(macOS 15.0, *) {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            } else {
                try startLegacyMicrophone()
            }
        }
        self.stream = stream
        try timeline.start()
        try await stream.startCapture()
        micSession?.startRunning()
        log.info("recording started \(streamConfig.width)x\(streamConfig.height) @\(self.config.framesPerSecond)fps")
    }

    func pause() {
        queue.sync { try? timeline.pause(nowNs: Self.hostNow()) }
    }

    func resume() {
        queue.sync { try? timeline.resume(nowNs: Self.hostNow()) }
    }

    /// Stops capture and finalizes the file. Returns the output URL.
    func stop() async throws -> URL {
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        let (writer, started) = queue.sync { () -> (AVAssetWriter?, Bool) in
            try? timeline.stop()
            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            micInput?.markAsFinished()
            return (self.writer, sessionStarted)
        }
        guard let writer else { throw RecordingError.writerFailed("writer missing") }
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.emptyRecording
        }
        writer.endSession(atSourceTime: CMTime(value: timeline.durationNs(), timescale: 1_000_000_000))
        await writer.finishWriting()
        log.info("recording finished: \(self.writtenFrames) frames, \(self.droppedFrames) dropped")
        if writer.status != .completed {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        return outputURL
    }

    /// Stops capture and deletes any partial file.
    func cancel() async {
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        queue.sync {
            try? timeline.stop()
            writer?.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    var duration: TimeInterval {
        queue.sync { Double(timeline.durationNs()) / 1e9 }
    }

    // MARK: - Setup

    private func makeStreamConfiguration(content: SCShareableContent) throws -> (SCContentFilter, SCStreamConfiguration) {
        let sc = SCStreamConfiguration()
        let filter: SCContentFilter
        let pixels: PixelRect

        switch config.source {
        case .region(let region):
            guard let display = ScreenCapture.bestDisplay(for: region, in: content.displays) else {
                throw RecordingError.noDisplay
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            let excluded = content.windows.filter { w in
                w.owningApplication?.processID == pid
                    || (config.hideDesktopIcons
                        && w.owningApplication?.bundleIdentifier == "com.apple.finder"
                        && w.windowLayer == iconLevel)
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = Double(filter.pointPixelScale)
            pixels = try selectionToPixels(
                display: DisplayGeometry(frame: Rect(cg: display.frame), scale: scale),
                selection: Rect(cg: region)
            )
            sc.sourceRect = CGRect(
                x: Double(pixels.x) / scale, y: Double(pixels.y) / scale,
                width: Double(pixels.width) / scale, height: Double(pixels.height) / scale
            )
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingError.windowNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixels = try displayPixelSize(display: DisplayGeometry(
                frame: Rect(cg: filter.contentRect), scale: Double(filter.pointPixelScale)
            ))
            sc.ignoreShadowsSingleWindow = true
        }

        // H.264/HEVC need even dimensions.
        sc.width = max(2, Int(pixels.width) & ~1)
        sc.height = max(2, Int(pixels.height) & ~1)
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.framesPerSecond))
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.colorSpaceName = CGColorSpace.sRGB
        sc.queueDepth = 6
        sc.showsCursor = config.showsCursor
        sc.capturesAudio = config.systemAudio
        sc.excludesCurrentProcessAudio = true
        sc.sampleRate = 48_000
        sc.channelCount = 2
        if #available(macOS 15.0, *), config.microphone {
            sc.captureMicrophone = true
        }
        return (filter, sc)
    }

    private func makeWriter(width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixelsPerSecond = Double(width * height * config.framesPerSecond)
        let bitsPerPixel = config.codec == .hevc ? 0.05 : 0.08
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: config.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * bitsPerPixel),
                AVVideoExpectedSourceFrameRateKey: config.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: config.framesPerSecond * 2,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingError.writerFailed("cannot add video track") }
        writer.add(video)
        videoInput = video

        // System audio and microphone are separate AAC tracks.
        if config.systemAudio { systemAudioInput = try addAudioInput(to: writer) }
        if config.microphone { micInput = try addAudioInput(to: writer) }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "cannot start")
        }
        self.writer = writer
    }

    private func addAudioInput(to writer: AVAssetWriter) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed("cannot add audio track") }
        writer.add(input)
        return input
    }

    /// macOS 14: microphone through AVCaptureSession. Its samples use the host
    /// clock, matching ScreenCaptureKit timestamps.
    private func startLegacyMicrophone() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecordingError.writerFailed("cannot configure microphone")
        }
        session.addInput(input)
        session.addOutput(output)
        micSession = session
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private static func hostNow() -> Int64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return Int64(CMTimeGetSeconds(t) * 1e9)
    }

    // MARK: - Sample handling (on `queue`)

    fileprivate func handle(_ sample: CMSampleBuffer, kind: SampleKind) {
        guard let writer, writer.status == .writing, CMSampleBufferDataIsReady(sample) else { return }

        if kind == .video {
            guard Self.isCompleteFrame(sample) else { return }
        } else if !sessionStarted {
            return // The session starts with the first video frame.
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        guard let outNs = timeline.map(ptsNs: Int64(CMTimeGetSeconds(pts) * 1e9)) else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }

        let input: AVAssetWriterInput? = switch kind {
        case .video: videoInput
        case .systemAudio: systemAudioInput
        case .microphone: micInput
        }
        guard let input else { return }
        guard input.isReadyForMoreMediaData else {
            if kind == .video { droppedFrames += 1 }
            return
        }
        guard let retimed = Self.retime(sample, to: CMTime(value: outNs, timescale: 1_000_000_000)) else { return }
        if input.append(retimed) {
            if kind == .video { writtenFrames += 1 }
        } else if writer.status == .failed {
            log.error("writer failed: \(writer.error?.localizedDescription ?? "", privacy: .public)")
            fail(RecordingError.writerFailed(writer.error?.localizedDescription ?? "append failed"))
        }
    }

    private func fail(_ error: Error) {
        guard streamError == nil else { return }
        streamError = error
        DispatchQueue.main.async { self.onUnexpectedStop?(error) }
    }

    private static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    private static func retime(_ sample: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timing.count, arrayToFill: &timing, entriesNeededOut: &count)
        let offset = CMTimeSubtract(pts, CMSampleBufferGetPresentationTimeStamp(sample))
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
            timing[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timing.count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

fileprivate enum SampleKind { case video, systemAudio, microphone }

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: handle(sampleBuffer, kind: .video)
        case .audio: handle(sampleBuffer, kind: .systemAudio)
        case .microphone: handle(sampleBuffer, kind: .microphone)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        queue.async { self.fail(error) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handle(sampleBuffer, kind: .microphone)
    }
}
