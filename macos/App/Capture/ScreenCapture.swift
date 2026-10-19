import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case windowNotFound
    case invalidGeometry(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available to capture."
        case .windowNotFound: "The selected window is no longer available."
        case .invalidGeometry(let m): "Invalid capture geometry: \(m)"
        }
    }
}

struct CaptureOptions {
    var hideDesktopIcons = false
    var includeWindowShadow = true
    var showsCursor = false
}

/// Stills via `SCScreenshotManager`. All rects are global points with a
/// top-left origin (see `snapora-core::geometry`).
enum ScreenCapture {
    static func captureMainDisplay(options: CaptureOptions = .init()) async throws -> CGImage {
        let content = try await shareableContent()
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        return try await capture(region: display.frame, on: display, content: content, options: options)
    }

    /// Captures `region` from the display it overlaps most. Parts outside that
    /// display are clipped.
    static func capture(region: CGRect, options: CaptureOptions = .init()) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = bestDisplay(for: region, in: content.displays) else {
            throw CaptureError.noDisplay
        }
        return try await capture(region: region, on: display, content: content, options: options)
    }

    static func capture(windowID: CGWindowID, options: CaptureOptions = .init()) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixels = try geometry {
            try displayPixelSize(display: DisplayGeometry(
                frame: Rect(cg: filter.contentRect),
                scale: Double(filter.pointPixelScale)
            ))
        }
        let config = baseConfiguration(options)
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.ignoreShadowsSingleWindow = !options.includeWindowShadow
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Internals

    private static func capture(region: CGRect, on display: SCDisplay, content: SCShareableContent, options: CaptureOptions) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content, options: options))
        let scale = Double(filter.pointPixelScale)
        let pixels = try geometry {
            try selectionToPixels(
                display: DisplayGeometry(frame: Rect(cg: display.frame), scale: scale),
                selection: Rect(cg: region)
            )
        }
        let config = baseConfiguration(options)
        // sourceRect is display-local points; derive it from the pixel rect so
        // the output size and source area agree exactly.
        config.sourceRect = CGRect(
            x: Double(pixels.x) / scale,
            y: Double(pixels.y) / scale,
            width: Double(pixels.width) / scale,
            height: Double(pixels.height) / scale
        )
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func baseConfiguration(_ options: CaptureOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = options.showsCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    /// Snapora's own windows (overlays, previews) and optionally Finder's
    /// desktop icons.
    private static func excludedWindows(in content: SCShareableContent, options: CaptureOptions) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        return content.windows.filter { w in
            if w.owningApplication?.processID == pid { return true }
            if options.hideDesktopIcons,
               w.owningApplication?.bundleIdentifier == "com.apple.finder",
               w.windowLayer == iconLevel {
                return true
            }
            return false
        }
    }

    static func bestDisplay(for region: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays.max { a, b in
            area(a.frame.intersection(region)) < area(b.frame.intersection(region))
        }.flatMap { area($0.frame.intersection(region)) > 0 ? $0 : nil }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private static func geometry<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw CaptureError.invalidGeometry(error.localizedDescription) }
    }
}

extension Rect {
    init(cg r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Conversions between AppKit screen space (bottom-left origin) and global
/// capture space (top-left origin). The flip is its own inverse.
enum GlobalSpace {
    static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    static func fromAppKit(_ r: CGRect) -> CGRect {
        appkitToGlobal(rect: Rect(cg: r), primaryHeight: primaryHeight).cgRect
    }

    static func toAppKit(_ r: CGRect) -> CGRect { fromAppKit(r) }
}
