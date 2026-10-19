import SwiftUI

/// Popover with every background control. Edits `model.background`.
struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Background", isOn: $model.background.enabled).toggleStyle(.switch).font(.headline)

            Group {
                section("Fill") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(BackgroundPresets.gradients, id: \.self) { spec in
                            swatch(selected: model.background.fill == .gradient(spec)) {
                                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(
                                    colors: [spec.start.color, spec.end.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                            .help(spec.name ?? "Gradient")
                            .onTapGesture { model.background.fill = .gradient(spec) }
                        }
                        ForEach(BackgroundPresets.solids, id: \.self) { c in
                            swatch(selected: model.background.fill == .solid(c)) {
                                RoundedRectangle(cornerRadius: 6).fill(c.color)
                            }
                            .onTapGesture { model.background.fill = .solid(c) }
                        }
                        swatch(selected: model.background.fill == .transparent) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                                .overlay(Image(systemName: "checkerboard.rectangle").foregroundStyle(.secondary))
                        }
                        .help("Transparent (PNG keeps transparency; JPEG becomes white)")
                        .onTapGesture { model.background.fill = .transparent }
                    }
                    fillEditor
                }

                section("Padding  \(Int(model.background.padding)) px") {
                    Slider(value: $model.background.padding, in: BackgroundStyle.paddingRange)
                }
                section("Corner radius  \(Int(model.background.cornerRadius)) px") {
                    Slider(value: $model.background.cornerRadius, in: BackgroundStyle.cornerRange)
                }
                section("Shadow") {
                    Toggle("Drop shadow", isOn: $model.background.shadow.enabled)
                    if model.background.shadow.enabled {
                        HStack {
                            Text("Blur").frame(width: 50, alignment: .leading)
                            Slider(value: $model.background.shadow.radius, in: BackgroundStyle.shadowRadiusRange)
                        }
                        HStack {
                            Text("Opacity").frame(width: 50, alignment: .leading)
                            Slider(value: $model.background.shadow.opacity, in: 0...1)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 20) {
                    section("Aspect ratio") {
                        Picker("", selection: $model.background.aspect) {
                            ForEach(BackgroundAspect.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    section("Alignment") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 3), spacing: 4) {
                            ForEach(BackgroundAlignment.allCases) { a in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(model.background.alignment == a ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .frame(width: 18, height: 14)
                                    .onTapGesture { model.background.alignment = a }
                            }
                        }
                        .opacity(model.background.aspect == .auto ? 0.4 : 1)
                        .help("Position of the image inside the canvas (needs a fixed aspect ratio)")
                    }
                }
            }
            .disabled(!model.background.enabled)
            .opacity(model.background.enabled ? 1 : 0.5)
        }
        .padding(14)
        .frame(width: 290)
    }

    @ViewBuilder private var fillEditor: some View {
        switch model.background.fill {
        case .solid(let c):
            HStack {
                Text("Custom colour")
                ColorPicker("", selection: Binding(get: { c.color }, set: { model.background.fill = .solid(BGColor(NSColor($0))) }),
                            supportsOpacity: false).labelsHidden()
            }
        case .gradient(let spec):
            HStack {
                ColorPicker("", selection: Binding(get: { spec.start.color },
                                                   set: { c in editGradient { $0.start = BGColor(NSColor(c)) } }),
                            supportsOpacity: false).labelsHidden()
                ColorPicker("", selection: Binding(get: { spec.end.color },
                                                   set: { c in editGradient { $0.end = BGColor(NSColor(c)) } }),
                            supportsOpacity: false).labelsHidden()
                Slider(value: Binding(get: { spec.angle }, set: { a in editGradient { $0.angle = a } }), in: 0...360)
                Text("\(Int(spec.angle))°").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
        case .transparent:
            ColorPicker("Custom colour", selection: Binding(get: { .white }, set: { model.background.fill = .solid(BGColor(NSColor($0))) }),
                        supportsOpacity: false)
        }
    }

    /// Edits the current gradient; custom edits drop the preset name.
    private func editGradient(_ edit: (inout GradientSpec) -> Void) {
        guard case .gradient(var s) = model.background.fill else { return }
        edit(&s)
        s.name = nil
        model.background.fill = .gradient(s)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func swatch<C: View>(selected: Bool, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: 34, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4),
                                                              lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
    }
}
