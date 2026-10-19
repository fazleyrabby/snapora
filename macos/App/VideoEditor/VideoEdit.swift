import AVFoundation
import CoreMedia

enum VideoQuality: Int, CaseIterable, Identifiable {
    case low, medium, high, ultra
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .ultra: "Ultra"
        }
    }
    /// Bits per pixel per frame used to derive the H.264 average bitrate.
    var bitsPerPixel: Double {
        switch self {
        case .low: 0.04
        case .medium: 0.07
        case .high: 0.11
        case .ultra: 0.18
        }
    }
}

enum AudioMode: String, CaseIterable, Identifiable {
    case keep, mono, mute, volume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: "Don't change"
        case .mono: "Convert to mono"
        case .mute: "Mute"
        case .volume: "Change volume"
        }
    }
}

/// Nondestructive edit decisions. Nothing is rendered until export.
struct VideoEdit {
    /// Kept range, in source-asset time.
    var trim: CMTimeRange
    /// Crop in display-oriented video pixels (top-left origin); nil = full frame.
    var crop: CGRect?
    var audio: AudioMode = .keep
    /// Linear gain, 0...2; only used when `audio == .volume`.
    var volume: Double = 1
    var quality: VideoQuality = .high
    /// Final encoded pixel size (even integers). Nil = the cropped size.
    var outputSize: CGSize?
}

enum SizeEstimate {
    static let monoAudioBitrate = 64_000.0
    static let stereoAudioBitrate = 128_000.0

    static func videoBitrate(quality: VideoQuality, size: CGSize, fps: Double) -> Double {
        quality.bitsPerPixel * Double(size.width) * Double(size.height) * (fps > 0 ? fps : 30)
    }

    static func audioBitrate(channels: Int) -> Double {
        channels <= 1 ? monoAudioBitrate : stereoAudioBitrate
    }

    /// (video + audio bitrate) x duration / 8.
    static func mp4Bytes(quality: VideoQuality, size: CGSize, fps: Double, audioChannels: Int?, duration: Double) -> Double {
        let audio = audioChannels.map(audioBitrate(channels:)) ?? 0
        return (videoBitrate(quality: quality, size: size, fps: fps) + audio) * max(0, duration) / 8
    }

    /// Rough GIF size: frames x w x h x 0.25 bytes.
    static func gifBytes(size: CGSize, fps: Int, duration: Double) -> Double {
        let scale = min(1, Double(GIFExporter.maxOutputWidth) / max(1, size.width))
        let w = size.width * scale, h = size.height * scale
        let frames = min(Double(GIFExporter.maxFrames), max(1, (duration * Double(fps)).rounded(.down)))
        return frames * w * h * 0.25
    }
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
