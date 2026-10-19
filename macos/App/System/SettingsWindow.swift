import AppKit
import SwiftUI

/// Preferences window. Options live here (not in the menu-bar menu) because
/// an NSMenu closes after every click.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: .shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Snapora Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureTab(settings: settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            RecordingTab(settings: settings)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: Settings
    @AppStorage(HistoryService.retentionKey) private var retentionDays = 0

    var body: some View {
        Form {
            Picker("After capture:", selection: $settings.afterCapture) {
                ForEach(AfterCaptureAction.allCases) { Text($0.label).tag($0) }
            }
            Picker("After recording:", selection: $settings.afterRecording) {
                ForEach(AfterRecordingAction.allCases) { Text($0.label).tag($0) }
            }
            Picker("Quick Access auto-close:", selection: $settings.quickAccessAutoCloseSeconds) {
                Text("Never").tag(0)
                ForEach([5, 10, 30], id: \.self) { Text("After \($0) seconds").tag($0) }
            }

            Divider().padding(.vertical, 4)

            LabeledContent("Save to:") {
                HStack {
                    Text(settings.saveDirectory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            TextField("File name:", text: $settings.fileNameTemplate)
            LabeledContent("Preview:") {
                Text(captureFileName(template: settings.fileNameTemplate, extension: "png"))
                    .foregroundStyle(.secondary)
            }
            Text("Tokens: {yyyy} {MM} {dd} {HH} {mm} {ss}")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Picker("Keep history:", selection: $retentionDays) {
                Text("Forever").tag(0)
                Text("1 week").tag(7)
                Text("1 month").tag(30)
                Text("3 months").tag(90)
                Text("1 year").tag(365)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}

private struct CaptureTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Toggle("Hide desktop icons while capturing", isOn: $settings.hideDesktopIcons)
            Toggle("Include window shadow", isOn: $settings.includeWindowShadow)
            Picker("Self-timer:", selection: $settings.timerSeconds) {
                ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
            }
        }
    }
}

private struct RecordingTab: View {
    @ObservedObject var settings: Settings
    @State private var devices = Microphones.available()

    var body: some View {
        Form {
            Picker("Frame rate:", selection: $settings.recordFPS) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Toggle("Show cursor", isOn: $settings.recordShowsCursor)
            Toggle("Record system audio", isOn: $settings.recordSystemAudio)
            Toggle("Record microphone", isOn: $settings.recordMicrophone)
            Picker("Microphone:", selection: $settings.recordMicrophoneID) {
                Text(Microphones.systemDefault.map { "System Default (\($0.name))" } ?? "System Default").tag("")
                ForEach(devices) { Text($0.name).tag($0.id) }
            }
            .disabled(!settings.recordMicrophone)
            Toggle("Use HEVC (smaller files)", isOn: $settings.recordHEVC)
            Text("These options are also in the recording bar (⌥⇧5).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { devices = Microphones.available() }
    }
}

private struct ShortcutsTab: View {
    private let shortcuts: [(String, String)] = [
        ("All-in-One", "⌥⇧1"),
        ("Capture Window", "⌥⇧2"),
        ("Capture Fullscreen", "⌥⇧3"),
        ("Capture Area", "⌥⇧4"),
        ("Record Screen / Stop", "⌥⇧5"),
        ("Capture Previous Area", "⌥⇧6"),
        ("Capture Text (OCR)", "⌥⇧O"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shortcuts, id: \.0) { name, keys in
                HStack {
                    Text(name)
                    Spacer()
                    Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text("In the capture overlay: A area · W window · F display · Space toggle · Return confirm · Esc cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
