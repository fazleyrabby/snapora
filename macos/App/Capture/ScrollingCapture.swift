import AppKit
import SwiftUI

/// Manual scrolling capture: the user scrolls inside a fixed region while
/// frames are captured and stitched by the Rust core.
@MainActor
final class ScrollingCapture: ObservableObject {
    struct Result {
        let image: CGImage
        let uncertainJoins: Int
    }

    @Published private(set) var height = 0
    @Published private(set) var uncertainJoins = 0
    @Published private(set) var lastOutcome: String = "Scroll down slowly"

    private let region: CGRect
    private let options: CaptureOptions
    private var stitcher: ScrollStitcher?
    private var loop: Task<Void, Never>?
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<Result?, Error>?

    static let maxRows: UInt32 = 30_000
    static let interval: Duration = .milliseconds(250)

    private init(region: CGRect, options: CaptureOptions) {
        self.region = region
        self.options = options
    }

    /// Runs until the user presses Done (returns the image) or Cancel (nil).
    static func run(region: CGRect, options: CaptureOptions) async throws -> Result? {
        let session = ScrollingCapture(region: region, options: options)
        let first = try await ScreenCapture.capture(region: region, options: options)
        let stitcher = try await Task.detached(priority: .userInitiated) {
            let buffer = try PixelBuffer(first)
            return try ScrollStitcher(
                width: buffer.width, height: buffer.height, bytesPerRow: buffer.bytesPerRow,
                data: buffer.data, maxRows: maxRows
            )
        }.value
        session.stitcher = stitcher
        session.height = Int(stitcher.height())
        return try await withCheckedThrowingContinuation { c in
            session.continuation = c
            session.showUI()
            session.startLoop()
        }
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                await self.captureFrame()
            }
        }
    }

    private func captureFrame() async {
        guard let stitcher else { return }
        do {
            let image = try await ScreenCapture.capture(region: region, options: options)
            // Pixel conversion and matching are heavy; keep them off the main actor.
            let (outcome, newHeight) = try await Task.detached(priority: .userInitiated) {
                let buffer = try PixelBuffer(image)
                let outcome = try stitcher.push(
                    width: buffer.width, height: buffer.height, bytesPerRow: buffer.bytesPerRow, data: buffer.data
                )
                return (outcome, Int(stitcher.height()))
            }.value
            guard continuation != nil else { return } // finished meanwhile
            height = newHeight
            switch outcome {
            case .appended(_, let uncertain):
                if uncertain { uncertainJoins += 1 }
                lastOutcome = uncertain ? "Join uncertain — scroll slower" : "Capturing…"
            case .noMovement:
                lastOutcome = "Scroll down slowly"
            case .noMatch:
                lastOutcome = "Lost track — scroll back a little, more slowly"
            case .sizeChanged:
                lastOutcome = "Region changed"
            case .limitReached:
                lastOutcome = "Maximum height reached"
            }
        } catch {
            lastOutcome = "Capture failed: \(error.localizedDescription)"
        }
    }

    fileprivate func done() {
        loop?.cancel()
        teardownUI()
        guard let continuation else { return }
        self.continuation = nil
        let stitcher = self.stitcher
        Task.detached(priority: .userInitiated) {
            do {
                guard let stitcher else { throw CaptureError.invalidGeometry("no frames") }
                let result = try stitcher.finish()
                let image = try PixelBuffer.makeImage(
                    width: Int(result.width), height: Int(result.height), data: result.data
                )
                continuation.resume(returning: Result(image: image, uncertainJoins: Int(result.uncertainJoins)))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    fileprivate func cancel() {
        loop?.cancel()
        teardownUI()
        continuation?.resume(returning: nil)
        continuation = nil
    }

    // MARK: - UI

    private func showUI() {
        let appKit = GlobalSpace.toAppKit(region)
        let screen = NSScreen.screens.first { $0.frame.intersects(appKit) } ?? NSScreen.main

        let border = NSPanel(contentRect: appKit.insetBy(dx: -4, dy: -4), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.level = .screenSaver
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = DashedBorderView(frame: CGRect(origin: .zero, size: border.frame.size))
        border.orderFrontRegardless()
        panels.append(border)

        let host = NSHostingView(rootView: ScrollingControls(session: self))
        let size = host.fittingSize
        let controls = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        controls.contentView = host
        controls.isOpaque = false
        controls.backgroundColor = .clear
        controls.hasShadow = true
        controls.level = .statusBar
        controls.isMovableByWindowBackground = true
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Below the region if there is room, otherwise above it.
        let vf = screen?.visibleFrame ?? appKit
        var origin = CGPoint(x: appKit.midX - size.width / 2, y: appKit.minY - size.height - 12)
        if origin.y < vf.minY { origin.y = min(appKit.maxY + 12, vf.maxY - size.height) }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        controls.setFrameOrigin(origin)
        controls.orderFrontRegardless()
        panels.append(controls)
    }

    private func teardownUI() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }
}

private struct ScrollingControls: View {
    @ObservedObject var session: ScrollingCapture

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.lastOutcome).font(.callout)
                Text("\(session.height) px\(session.uncertainJoins > 0 ? " · \(session.uncertainJoins) uncertain" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(session.uncertainJoins > 0 ? .orange : .secondary)
            }
            Button("Cancel") { session.cancel() }
            Button("Done") { session.done() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

/// CGImage <-> tightly packed BGRA (little-endian, premultiplied first).
struct PixelBuffer {
    let width: UInt32
    let height: UInt32
    let bytesPerRow: UInt32
    let data: Data

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(_ image: CGImage) throws {
        let w = image.width, h = image.height, bpr = w * 4
        var bytes = Data(count: bpr * h)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw CaptureError.invalidGeometry("cannot read pixels") }
        width = UInt32(w)
        height = UInt32(h)
        bytesPerRow = UInt32(bpr)
        data = bytes
    }

    static func makeImage(width: Int, height: Int, data: Data) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw CaptureError.invalidGeometry("cannot build stitched image") }
        return image
    }
}
