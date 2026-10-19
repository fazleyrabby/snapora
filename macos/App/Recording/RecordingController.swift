import AppKit
import OSLog
import SwiftUI

/// Owns the active recording, its floating controls, and the region border.
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, paused, stopping }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    /// Called with the finished file.
    var onFinished: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private var recorder: ScreenRecorder?
    private var ticker: Timer?
    private var controlPanel: NSPanel?
    private var borderPanel: NSPanel?
    private let log = Logger(subsystem: "com.snapora.app", category: "recording")

    var isActive: Bool { phase != .idle }

    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Snapora/Recordings", isDirectory: true)
    }

    func start(config: RecordingConfig, template: String) async {
        guard phase == .idle else { return }
        phase = .starting
        do {
            try FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
            let name = captureFileName(template: template, extension: "mp4")
            let url = ImageExporter.uniqueURL(in: Self.recordingsDirectory, fileName: name)
            let recorder = ScreenRecorder(config: config, outputURL: url)
            recorder.onUnexpectedStop = { [weak self] error in
                self?.log.error("recording interrupted")
                self?.onError?("Recording stopped: \(error.localizedDescription)")
                Task { await self?.stop() }
            }
            try await recorder.start()
            self.recorder = recorder
            phase = .recording
            showControls(for: config.source)
            startTicker()
        } catch {
            phase = .idle
            onError?("Could not start recording: \(error.localizedDescription)")
        }
    }

    func togglePause() {
        guard let recorder else { return }
        switch phase {
        case .recording:
            recorder.pause()
            phase = .paused
        case .paused:
            recorder.resume()
            phase = .recording
        default:
            break
        }
    }

    func stop() async {
        guard let recorder, phase == .recording || phase == .paused else { return }
        phase = .stopping
        teardownUI()
        do {
            let url = try await recorder.stop()
            onFinished?(url)
        } catch {
            onError?(error.localizedDescription)
        }
        self.recorder = nil
        phase = .idle
        elapsed = 0
    }

    func cancel() async {
        guard let recorder else { return }
        phase = .stopping
        teardownUI()
        await recorder.cancel()
        self.recorder = nil
        phase = .idle
        elapsed = 0
    }

    // MARK: - UI

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.duration
            }
        }
    }

    private func teardownUI() {
        ticker?.invalidate()
        ticker = nil
        controlPanel?.orderOut(nil)
        borderPanel?.orderOut(nil)
        controlPanel = nil
        borderPanel = nil
    }

    private func showControls(for source: RecordingConfig.Source) {
        var screen = NSScreen.main ?? NSScreen.screens.first
        if case .region(let rect) = source {
            let appKit = GlobalSpace.toAppKit(rect)
            screen = NSScreen.screens.first { $0.frame.intersects(appKit) } ?? screen
            // Only frame partial regions; a full-display recording needs no border.
            if let s = screen, !appKit.insetBy(dx: -1, dy: -1).contains(s.frame) {
                showBorder(around: appKit)
            }
        }
        guard let screen else { return }

        let host = NSHostingView(rootView: RecordingControls(controller: self))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let vf = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: vf.midX - host.fittingSize.width / 2, y: vf.maxY - host.fittingSize.height - 12))
        panel.orderFrontRegardless()
        controlPanel = panel
    }

    private func showBorder(around rect: CGRect) {
        let inset: CGFloat = -4
        let frame = rect.insetBy(dx: inset, dy: inset)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = RecordingBorderView(frame: CGRect(origin: .zero, size: frame.size))
        panel.orderFrontRegardless()
        borderPanel = panel
    }
}

/// Dashed red frame just outside the recorded area. Snapora's own windows are
/// excluded from capture, so it never appears in the video.
private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

private struct RecordingControls: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.phase == .paused ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
            Text(Self.format(controller.elapsed))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
            Button {
                controller.togglePause()
            } label: {
                Image(systemName: controller.phase == .paused ? "play.fill" : "pause.fill")
            }
            .help(controller.phase == .paused ? "Resume" : "Pause")
            Button {
                Task { await controller.stop() }
            } label: {
                Image(systemName: "stop.fill")
            }
            .help("Stop and save (⌥⇧5)")
            Button {
                Task { await controller.cancel() }
            } label: {
                Image(systemName: "trash")
            }
            .help("Discard recording")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.8), in: Capsule())
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
