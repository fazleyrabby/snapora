import AVFoundation
import CoreMedia

/// Nondestructive edit decisions. Nothing is rendered until export.
struct VideoEdit {
    /// Kept range, in source-asset time.
    var trim: CMTimeRange
    /// Crop in display-oriented video pixels (top-left origin); nil = full frame.
    var crop: CGRect?
    var muteAudio: Bool
}

enum VideoEditError: LocalizedError {
    case noVideoTrack
    case cannotCreateComposition
    case cannotCreateExportSession
    case cannotCreateDestination
    case frameGenerationFailed
    case writeFailed
    case exportFailed(String)
    case destinationIsSource

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .cannotCreateComposition: "Could not build the edited video."
        case .cannotCreateExportSession: "Could not start the video export."
        case .cannotCreateDestination: "Could not create the output file."
        case .frameGenerationFailed: "Could not read frames from the video."
        case .writeFailed: "Could not write the output file."
        case .exportFailed(let m): "Export failed: \(m)"
        case .destinationIsSource: "The export destination is the original recording. Choose a different file name so the original is not overwritten."
        }
    }
}

/// Display-oriented (preferredTransform applied) geometry of a video track.
struct VideoGeometry {
    var displaySize: CGSize
    var transform: CGAffineTransform
    var frameRate: Float

    static func load(from asset: AVAsset) async throws -> (track: AVAssetTrack, geometry: VideoGeometry) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditError.noVideoTrack
        }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(box.width).rounded(), height: abs(box.height).rounded())
        return (track, VideoGeometry(displaySize: size, transform: transform, frameRate: fps))
    }
}
