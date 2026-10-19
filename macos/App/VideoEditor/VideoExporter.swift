@preconcurrency import AVFoundation
import Foundation

/// Renders a `VideoEdit` to an H.264/AAC MP4 with AVAssetReader + AVAssetWriter.
/// The source is never modified. Trim, crop and scaling go through an
/// AVMutableComposition + AVMutableVideoComposition; volume and mono through
/// an AVMutableAudioMix and LPCM reader settings.
enum VideoExporter {
    /// Channel count of the first audio track (nil when there is none).
    static func sourceAudioChannels(of asset: AVAsset) async -> Int? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descs = try? await track.load(.formatDescriptions),
              let desc = descs.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else { return nil }
        return max(1, Int(asbd.mChannelsPerFrame))
    }

    static func export(
        asset: AVAsset,
        edit: VideoEdit,
        to url: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        if let src = (asset as? AVURLAsset)?.url,
           src.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            throw VideoEditError.destinationIsSource
        }
        let (sourceTrack, geometry) = try await VideoGeometry.load(from: asset)
        let sourceAudio = edit.audio == .mute ? [] : try await asset.loadTracks(withMediaType: .audio)
        let sourceChannels = await sourceAudioChannels(of: asset)

        // Composition: trimmed video (+ audio unless muted).
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoEditError.cannotCreateComposition }
        try videoTrack.insertTimeRange(edit.trim, of: sourceTrack, at: .zero)

        var audioTracks: [AVMutableCompositionTrack] = []
        for audio in sourceAudio {
            if let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try t.insertTimeRange(edit.trim, of: audio, at: .zero)
                    audioTracks.append(t)
                } catch {
                    composition.removeTrack(t)
                }
            }
        }
        let duration = composition.duration

        // Geometry: preferredTransform, then crop translate, then scale.
        let bounds = CGRect(origin: .zero, size: geometry.displaySize)
        let cropRect = edit.crop.map { CropMath.encodable($0, bounds: bounds) }
            ?? CropMath.encodable(bounds, bounds: bounds)
        let outSize = evenSize(edit.outputSize ?? cropRect.size)
        let transform = geometry.transform
            .concatenating(CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .concatenating(CGAffineTransform(scaleX: outSize.width / cropRect.width,
                                             y: outSize.height / cropRect.height))
        let fps = geometry.frameRate > 0 ? Double(geometry.frameRate) : 30

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        videoComposition.instructions = [instruction]

        // Reader.
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoEditError.cannotCreateComposition }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioSettings: [String: Any]?
        if !audioTracks.isEmpty {
            let channels = edit.audio == .mono ? 1 : min(2, sourceChannels ?? 2)
            let mix = AVMutableAudioMix()
            if edit.audio == .volume {
                mix.inputParameters = audioTracks.map { t in
                    let p = AVMutableAudioMixInputParameters(track: t)
                    p.setVolume(Float(min(2, max(0, edit.volume))), at: .zero)
                    return p
                }
            }
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = mix
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw VideoEditError.cannotCreateComposition }
            reader.add(out)
            audioOutput = out
            audioSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: Int(SizeEstimate.audioBitrate(channels: channels)),
            ]
        }

        // Writer (temp file beside the destination; swapped in at the end).
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".snapora-\(UUID().uuidString).mp4")
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: temp, fileType: .mp4) }
        catch { throw VideoEditError.cannotCreateDestination }
        writer.shouldOptimizeForNetworkUse = true

        let bitrate = Int(SizeEstimate.videoBitrate(quality: edit.quality, size: outSize, fps: fps))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(100_000, bitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 2,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoEditError.cannotCreateDestination }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw VideoEditError.cannotCreateDestination }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: temp)
            throw VideoEditError.exportFailed(writer.error?.localizedDescription ?? "cannot start writing")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temp)
            throw VideoEditError.exportFailed(reader.error?.localizedDescription ?? "cannot start reading")
        }
        writer.startSession(atSourceTime: .zero)

        let pump = SamplePump(
            reader: reader, writer: writer,
            video: (videoOutput, videoInput),
            audio: audioOutput.flatMap { o in audioInput.map { (o, $0) } },
            duration: duration.seconds, progress: progress
        )
        do {
            try await pump.run()
        } catch {
            removeTemp(temp)
            throw error
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw VideoEditError.writeFailed
        }
        progress(1)
    }

    /// Removes the temp file and any AVFoundation side files (`<name>.sb-*`).
    private static func removeTemp(_ temp: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: temp)
        let dir = temp.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(temp.lastPathComponent) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, (s.width / 2).rounded() * 2), height: max(2, (s.height / 2).rounded() * 2))
    }
}

/// Moves samples reader -> writer on a serial queue. All state is touched only
/// on `queue`, which is what makes the `@unchecked Sendable` sound.
private struct Pair: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    init(_ o: AVAssetReaderOutput, _ i: AVAssetWriterInput) { output = o; input = i }
}

private final class SamplePump: @unchecked Sendable {

    private let queue = DispatchQueue(label: "snapora.video-export")
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let video: Pair
    private let audio: Pair?
    private let duration: Double
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var remaining = 0
    private var done = false
    private var cancelRequested = false

    init(reader: AVAssetReader, writer: AVAssetWriter,
         video: (AVAssetReaderOutput, AVAssetWriterInput), audio: (AVAssetReaderOutput, AVAssetWriterInput)?,
         duration: Double, progress: @escaping (Double) -> Void) {
        self.reader = reader
        self.writer = writer
        self.video = Pair(video.0, video.1)
        self.audio = audio.map { Pair($0.0, $0.1) }
        self.duration = duration
        self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    continuation = c
                    if cancelRequested { finish(.failure(CancellationError())); return }
                    remaining = audio == nil ? 1 : 2
                    pump(video, reportsProgress: true)
                    if let audio { pump(audio, reportsProgress: false) }
                }
            }
        } onCancel: {
            queue.async { [self] in
                cancelRequested = true
                if continuation != nil { finish(.failure(CancellationError())) }
            }
        }
    }

    private func pump(_ pair: Pair, reportsProgress: Bool) {
        pair.input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !done else { return }
            while pair.input.isReadyForMoreMediaData {
                guard let sample = pair.output.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        finish(.failure(VideoEditError.exportFailed(reader.error?.localizedDescription ?? "read error")))
                        return
                    }
                    pair.input.markAsFinished()
                    remaining -= 1
                    if remaining == 0 { complete() }
                    return
                }
                if reportsProgress, duration > 0 {
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    progress(min(0.99, max(0, t / duration)))
                }
                if !pair.input.append(sample) {
                    finish(.failure(VideoEditError.exportFailed(writer.error?.localizedDescription ?? "write error")))
                    return
                }
            }
        }
    }

    private func complete() {
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed {
                    finish(.success(()))
                } else {
                    finish(.failure(VideoEditError.exportFailed(writer.error?.localizedDescription ?? "write error")))
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !done else { return }
        done = true
        if case .failure = result {
            reader.cancelReading()
            writer.cancelWriting()
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
