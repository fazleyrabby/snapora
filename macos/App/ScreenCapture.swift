import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case invalidGeometry(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available to capture."
        case .invalidGeometry(let m): "Invalid capture geometry: \(m)"
        }
    }
}

enum ScreenCapture {
    /// Captures the main display at native pixel resolution.
    static func captureMainDisplay() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        return try await capture(display: display)
    }

    static func capture(display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let geometry = DisplayGeometry(
            frame: Rect(cg: display.frame),
            scale: Double(filter.pointPixelScale)
        )
        let pixels: PixelRect
        do {
            pixels = try displayPixelSize(display: geometry)
        } catch {
            throw CaptureError.invalidGeometry(error.localizedDescription)
        }

        let config = SCStreamConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

extension Rect {
    init(cg r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
