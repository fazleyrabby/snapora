import AVFoundation
import Foundation

/// Renders a `VideoEdit` to an MP4. The source is never modified; trim, mute
/// and crop are applied through an AVMutableComposition + video composition
/// so the work is done once, by the hardware encoder.
enum VideoExporter {
    static func export(
        asset: AVAsset,
        edit: VideoEdit,
        to url: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let (sourceTrack, geometry) = try await VideoGeometry.load(from: asset)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoEditError.cannotCreateComposition }
        try videoTrack.insertTimeRange(edit.trim, of: sourceTrack, at: .zero)
        videoTrack.preferredTransform = geometry.transform

        if !edit.muteAudio {
            for audio in try await asset.loadTracks(withMediaType: .audio) {
                if let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? t.insertTimeRange(edit.trim, of: audio, at: .zero)
                }
            }
        }

        var videoComposition: AVMutableVideoComposition?
        if let crop = edit.crop {
            let bounds = CGRect(origin: .zero, size: geometry.displaySize)
            let rect = CropMath.encodable(crop, bounds: bounds)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(
                geometry.transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)),
                at: .zero
            )
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            instruction.layerInstructions = [layer]
            let vc = AVMutableVideoComposition()
            vc.renderSize = rect.size
            let fps = geometry.frameRate > 0 ? Int32(geometry.frameRate.rounded()) : 30
            vc.frameDuration = CMTime(value: 1, timescale: max(1, fps))
            vc.instructions = [instruction]
            videoComposition = vc
        }

        let session = try makeSession(for: composition)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)

        await run(session, progress: progress)

        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: url)
            throw VideoEditError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    private static func makeSession(for asset: AVAsset) throws -> AVAssetExportSession {
        for preset in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            if let s = AVAssetExportSession(asset: asset, presetName: preset) { return s }
        }
        throw VideoEditError.cannotCreateExportSession
    }

    private static func run(_ session: AVAssetExportSession, progress: @escaping (Double) -> Void) async {
        await withTaskCancellationHandler {
            let poller = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
            poller.cancel()
        } onCancel: {
            session.cancelExport()
        }
    }
}
