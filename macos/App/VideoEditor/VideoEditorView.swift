import AppKit
import AVFoundation
import AVKit
import SwiftUI

// MARK: - Preview

/// AVPlayerView without its own controls or hit-testing; the editor draws
/// custom controls and the crop overlay on top.
private final class PassivePlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = PassivePlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

// MARK: - Root view

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VStack(spacing: 10) {
            preview
            transport
            TrimTimelineView(model: model)
                .frame(height: 56)
            optionsBar
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 520)
        .overlay { if model.isExporting { exportOverlay } }
        .task { await model.load() }
        .alert(
            "Video Editor",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            let rect = Self.fit(model.displaySize, in: geo.size)
            ZStack {
                Color.black
                PlayerLayerView(player: model.player)
                if model.isReady {
                    CropOverlay(model: model, videoRect: rect)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Aspect-fit rect, matching AVPlayerView's .resizeAspect.
    static func fit(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let s = min(container.width / content.width, container.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")
            Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")
            Text("\(format(model.currentTime)) / \(format(model.duration))")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Text("Trim \(format(model.trimStart)) – \(format(model.trimEnd))  (\(format(model.trimEnd - model.trimStart)))")
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!model.isReady)
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.cropMode }, set: { model.setCropMode($0) })) {
                Label("Crop", systemImage: "crop")
            }
            .toggleStyle(.button)
            if model.cropMode {
                Picker("Aspect", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                    ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            if model.crop != nil {
                Button("Clear Crop") { model.clearCrop() }
            }
            Toggle(isOn: $model.muteAudio) { Label("Mute", systemImage: "speaker.slash") }
                .toggleStyle(.button)
                .disabled(!model.hasAudio)
            Spacer()
            Menu {
                Picker("Frame rate", selection: $model.gifFPS) {
                    ForEach([10, 15, 20, 24], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Max width", selection: $model.gifMaxWidth) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("800 px").tag(800)
                    Text("Original").tag(0)
                }
            } label: {
                Text("GIF: \(model.gifFPS) fps, \(model.gifMaxWidth == 0 ? "original" : "\(model.gifMaxWidth) px")")
            }
            .fixedSize()
            Button("Export GIF") { model.exportGIF() }
            Button("Export MP4") { model.exportMP4() }
                .keyboardShortcut("e", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .disabled(!model.isReady || model.isExporting)
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                Text(model.exportLabel).font(.headline)
                ProgressView(value: model.exportProgress ?? 0).frame(width: 260)
                Button("Cancel") { model.cancelExport() }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func format(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}

// MARK: - Crop overlay

private struct CropOverlay: View {
    @ObservedObject var model: VideoEditorModel
    let videoRect: CGRect

    private enum Drag {
        case move(start: CGRect, origin: CGPoint)
        case resize(anchor: CGPoint)
        case create(anchor: CGPoint)
    }
    @State private var drag: Drag?

    var body: some View {
        let scale = videoRect.width / max(1, model.displaySize.width)
        ZStack {
            if let crop = model.crop {
                let r = CGRect(
                    x: videoRect.minX + crop.minX * scale, y: videoRect.minY + crop.minY * scale,
                    width: crop.width * scale, height: crop.height * scale
                )
                Path { p in p.addRect(videoRect); p.addRect(r) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Rectangle().stroke(Color.white, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
                if model.cropMode {
                    ForEach(0..<4, id: \.self) { i in
                        let c = Self.corner(i, of: r)
                        Circle().fill(Color.white).frame(width: 10, height: 10)
                            .shadow(radius: 1).position(c).allowsHitTesting(false)
                    }
                    Text("\(Int(crop.width.rounded())) × \(Int(crop.height.rounded()))")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .position(x: r.midX, y: max(videoRect.minY + 12, r.minY - 12))
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(scale: scale), including: model.cropMode ? .all : .none)
    }

    private static func corner(_ i: Int, of r: CGRect) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)][i]
    }

    private func toVideo(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - videoRect.minX) / scale, y: (p.y - videoRect.minY) / scale)
    }

    private func dragGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let bounds = model.bounds
                let p = toVideo(v.location, scale: scale)
                if drag == nil {
                    let s = toVideo(v.startLocation, scale: scale)
                    drag = beginDrag(at: s, scale: scale)
                }
                switch drag {
                case .move(let start, let origin)?:
                    var r = start
                    r.origin.x += p.x - origin.x
                    r.origin.y += p.y - origin.y
                    model.crop = CropMath.constrain(rect: r, aspect: nil, bounds: bounds)
                case .resize(let anchor)?, .create(let anchor)?:
                    let r = CropMath.rect(anchor: anchor, point: p, aspect: model.aspect.ratio, bounds: bounds)
                    if r.width >= 4, r.height >= 4 { model.crop = r }
                case nil:
                    break
                }
            }
            .onEnded { _ in
                drag = nil
                if let c = model.crop, c.width < CropMath.minSize || c.height < CropMath.minSize {
                    model.crop = CropMath.defaultRect(aspect: model.aspect.ratio, bounds: model.bounds)
                }
            }
    }

    private func beginDrag(at s: CGPoint, scale: CGFloat) -> Drag {
        if let crop = model.crop {
            let corners = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                           CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)]
            let hit = 14 / scale
            for (i, c) in corners.enumerated() where hypot(c.x - s.x, c.y - s.y) <= hit {
                return .resize(anchor: corners[(i + 2) % 4])
            }
            if crop.contains(s) { return .move(start: crop, origin: s) }
        }
        return .create(anchor: s)
    }
}

// MARK: - Timeline

private struct TrimTimelineView: View {
    @ObservedObject var model: VideoEditorModel
    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dur = max(model.duration, 0.001)
            let xStart = CGFloat(model.trimStart / dur) * w
            let xEnd = CGFloat(model.trimEnd / dur) * w
            let xHead = CGFloat(model.currentTime / dur) * w

            ZStack(alignment: .topLeading) {
                thumbnailStrip(width: w, height: h)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, xStart), height: h)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, w - xEnd), height: h)
                    .offset(x: xEnd)
                Rectangle().stroke(Color.yellow, lineWidth: 2)
                    .frame(width: max(0, xEnd - xStart), height: h)
                    .offset(x: xStart)
                    .allowsHitTesting(false)

                // Playhead
                Rectangle().fill(Color.white).frame(width: 2, height: h + 8)
                    .shadow(radius: 1)
                    .offset(x: xHead - 1, y: -4)
                    .allowsHitTesting(false)

                handle(systemImage: "chevron.compact.right")
                    .offset(x: xStart - handleWidth)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { v in model.setTrimStart(time(at: v.location.x + handleWidth / 2, width: w)) })
                handle(systemImage: "chevron.compact.left")
                    .offset(x: xEnd)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { v in model.setTrimEnd(time(at: v.location.x - handleWidth / 2, width: w)) })
            }
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { v in
                    if model.isPlaying { model.pause(at: nil) }
                    model.seek(to: time(at: v.location.x, width: w))
                })
        }
        .disabled(!model.isReady)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x), width) / width) * model.duration
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
            .frame(width: handleWidth)
            .overlay(Image(systemName: systemImage).font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
    }

    private func thumbnailStrip(width: CGFloat, height: CGFloat) -> some View {
        let thumbs = model.thumbnails
        let cellW = thumbs.isEmpty ? width : width / CGFloat(thumbs.count)
        return HStack(spacing: 0) {
            ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                Group {
                    if let img {
                        Image(decorative: img, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.25)
                    }
                }
                .frame(width: cellW, height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.gray.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
