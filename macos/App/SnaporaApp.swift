import SwiftUI

@main
struct SnaporaApp: App {
    @StateObject private var model = AppModel()

    init() {
        initLogging()
    }

    var body: some Scene {
        MenuBarExtra("Snapora", systemImage: "camera.viewfinder") {
            MenuContent(model: model, settings: model.settings)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        Group {
            Button("All-in-One…  ⌥⇧1") { model.perform(.allInOne) }
            Button("Capture Area…  ⌥⇧4") { model.perform(.region) }
            Button("Capture Previous Area  ⌥⇧6") { model.perform(.previousArea) }
            Button("Capture Window…  ⌥⇧2") { model.perform(.window) }
            Button("Capture Fullscreen  ⌥⇧3") { model.perform(.fullscreen) }
            Button("Capture Text (OCR)…  ⌥⇧O") { model.perform(.ocr) }
            Button("Scrolling Capture…") { model.perform(.scrolling) }
            if let countdown = model.countdown {
                Button("Cancel Timer (\(countdown)s)") { model.cancelTimer() }
            } else {
                Button("Self-Timer (\(settings.timerSeconds)s)") { model.perform(.timedFullscreen) }
            }
        }
        .disabled(model.isCapturing || model.recording.isActive)

        Divider()

        RecordingMenu(model: model, recording: model.recording, settings: settings)

        Button("Reopen Last Capture") { model.reopenLastCapture() }
        Button("Capture History…") { HistoryWindow.show() }
        if model.lastRecording != nil {
            Button("Edit Last Recording…") { model.editLastRecording() }
        }
        PinsMenu()

        Divider()

        Toggle("Hide Desktop Icons", isOn: $settings.hideDesktopIcons)
        Toggle("Window Shadow", isOn: $settings.includeWindowShadow)
        Picker("Timer", selection: $settings.timerSeconds) {
            ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
        }
        Picker("After Capture", selection: $settings.afterCapture) {
            ForEach(AfterCaptureAction.allCases) { Text($0.label).tag($0) }
        }
        Picker("After Recording", selection: $settings.afterRecording) {
            ForEach(AfterRecordingAction.allCases) { Text($0.label).tag($0) }
        }
        Picker("Quick Access Auto-Close", selection: $settings.quickAccessAutoCloseSeconds) {
            Text("Never").tag(0)
            ForEach([5, 10, 30], id: \.self) { Text("\($0)s").tag($0) }
        }

        Divider()

        if !model.hasScreenPermission {
            Button("Grant Screen Recording Permission…") { model.requestPermission() }
        }
        if let status = model.statusMessage {
            Text(status)
        }

        Divider()

        Text("Snapora core \(coreVersion())")
        Button("Quit Snapora") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct RecordingMenu: View {
    let model: AppModel
    @ObservedObject var recording: RecordingController
    @ObservedObject var settings: Settings

    var body: some View {
        switch recording.phase {
        case .idle:
            Button("Record Screen…  ⌥⇧5") { model.perform(.recording) }
                .disabled(model.isCapturing)
            Menu("Recording Options") {
                Picker("Frame Rate", selection: $settings.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Record System Audio", isOn: $settings.recordSystemAudio)
                Toggle("Record Microphone", isOn: $settings.recordMicrophone)
                Picker("Microphone", selection: $settings.recordMicrophoneID) {
                    Text(Microphones.systemDefault.map { "System Default (\($0.name))" } ?? "System Default").tag("")
                    ForEach(Microphones.available()) { Text($0.name).tag($0.id) }
                }
                .disabled(!settings.recordMicrophone)
                Toggle("Show Cursor", isOn: $settings.recordShowsCursor)
                Toggle("HEVC (smaller files)", isOn: $settings.recordHEVC)
            }
        case .starting:
            Text("Starting recording…")
        case .recording, .paused:
            Button("Stop Recording  ⌥⇧5") { Task { await recording.stop() } }
            Button(recording.phase == .paused ? "Resume Recording" : "Pause Recording") { recording.togglePause() }
            Button("Discard Recording") { Task { await recording.cancel() } }
        case .stopping:
            Text("Saving recording…")
        }
    }
}

/// Locked pins ignore the mouse, so the menu bar is the way to unlock them.
/// Static pin state is not observable, so the items are always shown.
struct PinsMenu: View {
    var body: some View {
        Menu("Pinned Screenshots") {
            Button("Unlock All Pins") { PinnedImage.unlockAll() }
            Button("Close All Pins") { PinnedImage.closeAll() }
        }
    }
}
