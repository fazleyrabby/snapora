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
        VStack(spacing: 12) {
            preview
            timelineRow
            HStack(alignment: .top, spacing: 12) {
                videoPanel
                audioPanel
            }
            .fixedSize(horizontal: false, vertical: true)
            bottomBar
        }
        .padding(14)
        .frame(minWidth: 700, minHeight: 600)
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
        .preferredColorScheme(.dark)
        .overlay { if model.isExporting { exportOverlay } }
        .background(hiddenShortcuts)
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

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let rect = Self.fit(model.displaySize, in: geo.size)
            ZStack(alignment: .topTrailing) {
                Color.black
                PlayerLayerView(player: model.player)
                if model.isReady {
                    CropOverlay(model: model, videoRect: rect)
                }
                cropToolbar.padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cropToolbar: some View {
        HStack(spacing: 4) {
            if model.cropMode || model.crop != nil {
                Menu {
                    ForEach(CropAspect.allCases) { a in
                        Button {
                            model.setAspect(a)
                        } label: {
                            if model.aspect == a { Label(a.title, systemImage: "checkmark") } else { Text(a.title) }
                        }
                    }
                    if model.crop != nil {
                        Divider()
                        Button("Clear Crop") { model.clearCrop() }
                    }
                } label: {
                    Text(model.aspect.title).font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Crop aspect ratio")
            }
            Toggle(isOn: Binding(get: { model.cropMode }, set: { model.setCropMode($0) })) {
                Image(systemName: "crop")
            }
            .toggleStyle(.button)
            .help("Crop")
        }
        .padding(4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .disabled(!model.isReady || model.isExporting)
    }

    /// Aspect-fit rect, matching AVPlayerView's .resizeAspect.
    static func fit(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let s = min(container.width / content.width, container.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    // MARK: Transport + timeline

    private var timelineRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help("Play / pause (Space)")
                TrimTimelineView(model: model)
                    .frame(height: 56)
                    .padding(.horizontal, 12)
            }
            HStack {
                Text("\(format(model.currentTime)) / \(format(model.duration))")
                Spacer()
                Text("Trim \(format(model.trimStart)) – \(format(model.trimEnd))  (\(format(model.trimmedDuration)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 68)
        }
        .disabled(!model.isReady)
    }

    /// Invisible buttons that carry the Space / arrow shortcuts.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Panels

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
    }

    private var videoPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Format:").frame(width: 100, alignment: .leading)
                    Picker("", selection: $model.format) {
                        ForEach(VideoEditorModel.Format.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                if model.format == .mp4 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Video quality: ").foregroundStyle(.secondary)
                            + Text(model.quality.title).bold()
                        Slider(
                            value: Binding(get: { Double(model.quality.rawValue) },
                                           set: { model.quality = VideoQuality(rawValue: Int($0.rounded())) ?? .high }),
                            in: 0...3, step: 1
                        )
                        HStack {
                            Text("Low"); Spacer(); Text("Medium"); Spacer(); Text("High"); Spacer(); Text("Ultra")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Frame rate:").frame(width: 100, alignment: .leading)
                        Picker("", selection: $model.gifFPS) {
                            ForEach([10, 15, 20, 24], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                }
                HStack {
                    Text("Dimensions:").frame(width: 100, alignment: .leading)
                    Picker("", selection: Binding(get: { model.dimensionMode }, set: { model.setDimensionMode($0) })) {
                        ForEach(VideoEditorModel.DimensionMode.allCases) { Text(model.dimensionTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                HStack(spacing: 6) {
                    Text("Width:").foregroundStyle(.secondary)
                    TextField("", value: Binding(get: { model.outputWidth }, set: { model.outputWidth = $0 }), format: .number.grouping(.never))
                        .frame(width: 64)
                    Text("Height:").foregroundStyle(.secondary).padding(.leading, 6)
                    TextField("", value: Binding(get: { model.outputHeight }, set: { model.outputHeight = $0 }), format: .number.grouping(.never))
                        .frame(width: 64)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.dimensionMode != .custom)
                .padding(.leading, 100)
            }
        }
    }

    private var audioPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Audio:")
                Picker("", selection: $model.audioMode) {
                    ForEach(AudioMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $model.volume, in: 0...2)
                    HStack {
                        Text("0%"); Spacer()
                        Text("\(Int((model.volume * 100).rounded()))%").foregroundStyle(.primary)
                        Spacer(); Text("200%")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .disabled(model.audioMode != .volume)
                .padding(.leading, 20)
                if !model.hasAudio && model.isReady {
                    Text("No audio track").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.hasAudio)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button("Cancel") {
                if model.isExporting { model.cancelExport() } else { model.onCancel?() }
            }
            .keyboardShortcut(.cancelAction)
            Text("Estimated file size: \(model.estimatedSizeText)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Convert") { model.convert() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isReady || model.isExporting)
        }
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
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
    /// What the current drag moves; decided once, at mouse-down.
    @State private var dragTarget: DragTarget?
    private let handleWidth: CGFloat = 12

    private enum DragTarget { case start, end, playhead }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Handles sit inside the view, outside the [0, track] time range.
            let track = max(1, w - 2 * handleWidth)
            let dur = max(model.duration, 0.001)
            let x = { (t: Double) in handleWidth + CGFloat(t / dur) * track }
            let xStart = x(model.trimStart)
            let xEnd = x(model.trimEnd)
            let xHead = x(model.currentTime)

            ZStack(alignment: .topLeading) {
                thumbnailStrip(width: track, height: h)
                    .offset(x: handleWidth)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, xStart - handleWidth), height: h)
                    .offset(x: handleWidth)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, w - handleWidth - xEnd), height: h)
                    .offset(x: xEnd)
                Rectangle().stroke(Color.yellow, lineWidth: 2)
                    .frame(width: max(0, xEnd - xStart + 2 * handleWidth), height: h)
                    .offset(x: xStart - handleWidth)
                handle(systemImage: "chevron.compact.left")
                    .frame(height: h)
                    .offset(x: xStart - handleWidth)
                handle(systemImage: "chevron.compact.right")
                    .frame(height: h)
                    .offset(x: xEnd)
                Rectangle().fill(Color.white).frame(width: 2, height: h + 8)
                    .shadow(radius: 1)
                    .offset(x: xHead - 1, y: -4)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragTarget == nil {
                            dragTarget = target(at: v.startLocation.x, xStart: xStart, xEnd: xEnd)
                            if dragTarget == .playhead, model.isPlaying { model.pause(at: nil) }
                        }
                        let t = Double(min(max(0, v.location.x - handleWidth), track) / track) * model.duration
                        switch dragTarget {
                        case .start: model.setTrimStart(t)
                        case .end: model.setTrimEnd(t)
                        case .playhead, nil: model.seek(to: t)
                        }
                    }
                    .onEnded { _ in dragTarget = nil }
            )
        }
        .disabled(!model.isReady)
    }

    /// Handles win within a generous grab zone; the closer one wins when the
    /// trim range is short. Anywhere else scrubs.
    private func target(at x: CGFloat, xStart: CGFloat, xEnd: CGFloat) -> DragTarget {
        let grab = handleWidth + 6
        let dStart = abs(x - (xStart - handleWidth / 2))
        let dEnd = abs(x - (xEnd + handleWidth / 2))
        if min(dStart, dEnd) <= grab { return dStart <= dEnd ? .start : .end }
        return .playhead
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
