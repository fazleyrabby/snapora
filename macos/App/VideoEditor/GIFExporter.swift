import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFOptions: Equatable {
    var fps: Int = 15
    /// Maximum output width in pixels; nil keeps the (cropped) original width.
    var maxWidth: Int? = 640
}

/// Result of a GIF export; `reduced` is true when the frame rate or width was
/// lowered to stay within the work caps.
struct GIFExportInfo: Equatable {
    var requestedFPS: Int
    var effectiveFPS: Double
    var frameCount: Int
    var outputWidthCap: Int
    var reduced: Bool { effectiveFPS < Double(requestedFPS) - 0.01 }
}

/// Writes an animated GIF by stepping through a time range one frame at a time.
///
/// Memory bound: ImageIO's `CGImageDestination` retains every added frame until
/// `Finalize`, so peak memory is roughly `frames x width x height x 4` bytes.
/// That is capped by `maxFrames` frames and `maxOutputWidth` pixels of width.
enum GIFExporter {
    static let maxFrames = 600
    static let maxOutputWidth = 1280

    @discardableResult
    static func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        crop: CGRect?,
        options: GIFOptions,
        to url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> GIFExportInfo {
        let requested = max(1, options.fps)
        let start = timeRange.start.seconds
        let duration = timeRange.duration.seconds
        var fps = Double(requested)
        if duration * fps > Double(maxFrames), duration > 0 { fps = Double(maxFrames) / duration }
        let widthCap = min(options.maxWidth.flatMap { $0 > 0 ? $0 : nil } ?? maxOutputWidth, maxOutputWidth)
        let count = max(1, Int((duration * fps).rounded(.down)))
        let lastTime = max(start, start + duration - 0.001)
        let times = (0..<count).map {
            CMTime(seconds: min(start + Double($0) / fps, lastTime), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".snapora-\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(
            temp as CFURL, UTType.gif.identifier as CFString, count, nil
        ) else { throw VideoEditError.cannotCreateDestination }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps,
            ],
        ] as CFDictionary

        var written = 0
        do {
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                let image = try result.image
                try autoreleasepool {
                    guard let frame = process(image, crop: crop, maxWidth: widthCap) else {
                        throw VideoEditError.frameGenerationFailed
                    }
                    CGImageDestinationAddImage(dest, frame, frameProps)
                    written += 1
                }
                progress(Double(written) / Double(count) * 0.95)
            }
            try Task.checkCancellation()
            guard written == count else { throw VideoEditError.frameGenerationFailed }
            guard CGImageDestinationFinalize(dest) else { throw VideoEditError.writeFailed }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
            progress(1)
            return GIFExportInfo(requestedFPS: requested, effectiveFPS: fps, frameCount: count, outputWidthCap: widthCap)
        } catch {
            generator.cancelAllCGImageGeneration()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Crops (top-left-origin pixels) then scales one frame.
    private static func process(_ image: CGImage, crop: CGRect?, maxWidth: Int?) -> CGImage? {
        var img = image
        if let crop {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let r = crop.integral.intersection(bounds)
            guard !r.isEmpty, let cropped = image.cropping(to: r) else { return nil }
            img = cropped
        }
        guard let maxWidth, maxWidth > 0, img.width > maxWidth else { return img }
        let w = maxWidth
        let h = max(1, Int((Double(img.height) * Double(w) / Double(img.width)).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
