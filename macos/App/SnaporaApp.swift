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
            if let countdown = model.countdown {
                Button("Cancel Timer (\(countdown)s)") { model.cancelTimer() }
            } else {
                Button("Self-Timer (\(settings.timerSeconds)s)") { model.perform(.timedFullscreen) }
            }
        }
        .disabled(model.isCapturing)

        Button("Reopen Last Capture") { model.reopenLastCapture() }

        Divider()

        Toggle("Hide Desktop Icons", isOn: $settings.hideDesktopIcons)
        Toggle("Window Shadow", isOn: $settings.includeWindowShadow)
        Picker("Timer", selection: $settings.timerSeconds) {
            ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
        }
        Picker("After Capture", selection: $settings.afterCapture) {
            ForEach(AfterCaptureAction.allCases) { Text($0.label).tag($0) }
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
