@preconcurrency import AVFoundation
import AppKit

/// Video input devices available for the camera overlay.
enum Cameras {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private static var discoveryTypes: [AVCaptureDevice.DeviceType] {
        [.builtInWideAngleCamera, .external, .continuityCamera]
    }

    static func available() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: discoveryTypes, mediaType: .video, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var systemDefault: Device? {
        AVCaptureDevice.default(for: .video).map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen camera, or the default when `id` is empty or disconnected.
    static func resolve(_ id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let device = AVCaptureDevice(uniqueID: id) { return device }
        return AVCaptureDevice.default(for: .video)
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
}

enum CameraShape: String, CaseIterable, Identifiable {
    case circle, rounded
    var id: String { rawValue }
    var label: String { self == .circle ? "Circle" : "Rounded" }
}

enum CameraSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Bubble diameter / width in points.
    var points: CGFloat {
        switch self {
        case .small: 140
        case .medium: 200
        case .large: 280
        }
    }
}

enum CameraError: LocalizedError {
    case denied, unavailable

    var errorDescription: String? {
        switch self {
        case .denied: "Camera access was denied. Enable it in System Settings → Privacy & Security → Camera."
        case .unavailable: "No camera is available."
        }
    }
}

/// Floating, draggable live camera preview. During area and display
/// recordings this window is deliberately included in the video.
@MainActor
final class CameraBubble {
    private let panel: NSPanel
    private let session = AVCaptureSession()

    /// Window number for ScreenCaptureKit to include in the recording.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private init(panel: NSPanel) {
        self.panel = panel
    }

    /// Shows the bubble at the bottom-right of `region` (AppKit coordinates).
    static func show(deviceID: String, shape: CameraShape, size: CameraSize, in region: CGRect) async throws -> CameraBubble {
        guard await Cameras.requestAccess() else { throw CameraError.denied }
        guard let device = Cameras.resolve(deviceID) else { throw CameraError.unavailable }

        let side = min(size.points, region.width * 0.45, region.height * 0.45)
        let frame = CGRect(x: region.maxX - side - 24, y: region.minY + 24, width: side, height: side)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bubble = CameraBubble(panel: panel)
        let input = try AVCaptureDeviceInput(device: device)
        if bubble.session.canAddInput(input) { bubble.session.addInput(input) }
        bubble.session.sessionPreset = .high

        let view = CameraPreviewView(frame: CGRect(origin: .zero, size: frame.size), session: bubble.session, shape: shape)
        panel.contentView = view
        panel.orderFrontRegardless()

        let session = bubble.session
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning(); c.resume() }
        }
        return bubble
    }

    func close() {
        panel.orderOut(nil)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }
}

private final class CameraPreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let shape: CameraShape

    init(frame: CGRect, session: AVCaptureSession, shape: CameraShape) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        self.shape = shape
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        // Mirror like a video call.
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        layer?.addSublayer(preview)
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 3
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        preview.frame = bounds
        layer?.cornerRadius = shape == .circle ? bounds.width / 2 : 24
    }

    override var mouseDownCanMoveWindow: Bool { true }
}
