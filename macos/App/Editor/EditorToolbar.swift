import SwiftUI

struct EditorRootView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            ToolRow(model: model)
            Divider()
            OptionsRow(model: model)
            Divider()
            CanvasRepresentable(model: model)
            Divider()
            statusBar
        }
        .alert("Editor", isPresented: Binding(get: { model.errorMessage != nil },
                                              set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.statusMessage ?? "")
            Spacer()
            let size = model.exportLayout.canvasSize
            Text("\(Int(size.width)) × \(Int(size.height)) px  ·  \(model.zoomPercent)%")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct ToolRow: View {
    @ObservedObject var model: EditorModel
    @State private var showBackground = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                Button { model.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 26, height: 22)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.shortcut).uppercased()))"
                      + ([.blur, .pixelate].contains(tool) ? "\nUse Redact for sensitive data — only solid redaction is fully irreversible." : ""))
            }
            Divider().frame(height: 18)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
            Divider().frame(height: 18)
            Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
            Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
            if model.tool == .crop {
                Button("Apply Crop") { model.applyPendingCrop() }.help("Return")
                Button("Cancel") { model.cancelCrop() }.help("Esc")
            }
            if model.hasCrop {
                Button("Reset Crop") { model.resetCrop() }
            }
            Divider().frame(height: 18)
            Button { showBackground.toggle() } label: {
                Image(systemName: "photo.artframe")
                    .frame(width: 26, height: 22)
                    .background(model.background.enabled ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .help("Background")
            .popover(isPresented: $showBackground, arrowEdge: .bottom) { BackgroundPanel(model: model) }
            Spacer()
            Button { model.canvas?.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out (⌘-)")
            Button { model.canvas?.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit (⌘0)")
            Button { model.canvas?.zoomActualSize() } label: { Text("1:1") }.help("Actual size (⌘1)")
            Button { model.canvas?.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in (⌘+)")
            Divider().frame(height: 18)
            Button("Copy") { model.copyToPasteboard() }.help("Copy (⌘C)")
            Button("Save") { model.saveEdited() }.help("Save as “… edited.png” (⌘S)")
            Button("Save As…") { model.saveAs() }.help("⇧⌘S")
            Button("Done") { model.done() }.buttonStyle(.borderedProminent).help("Copy and close")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct OptionsRow: View {
    @ObservedObject var model: EditorModel

    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1),
        NSColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .black, .white,
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, c in
                Button { model.chooseColor(c) } label: {
                    Circle().fill(Color(nsColor: c))
                        .overlay(Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.strokeColor) },
                set: { model.chooseColor(NSColor($0)) }), supportsOpacity: false)
                .labelsHidden()
            Divider().frame(height: 18)
            Image(systemName: "lineweight")
            Slider(value: $model.lineWidth, in: 1...24).frame(width: 110)
            Text("\(Int(model.lineWidth))").monospacedDigit().frame(width: 22, alignment: .trailing)
            Divider().frame(height: 18)
            Image(systemName: "textformat.size")
            Slider(value: $model.fontSize, in: 10...120).frame(width: 110)
            Text("\(Int(model.fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
            Toggle("Fill", isOn: $model.fillEnabled)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
