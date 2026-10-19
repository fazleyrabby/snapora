import SwiftUI

@main
struct SnaporaApp: App {
    @StateObject private var model = AppModel()

    init() {
        initLogging()
    }

    var body: some Scene {
        MenuBarExtra("Snapora", systemImage: "camera.viewfinder") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Capture Fullscreen") { model.captureFullscreen() }
            .keyboardShortcut("3", modifiers: [.option, .shift])
            .disabled(model.isCapturing)

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
