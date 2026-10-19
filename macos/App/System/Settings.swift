import Foundation

/// User preferences backed by `UserDefaults`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }
    @Published var includeWindowShadow: Bool { didSet { defaults.set(includeWindowShadow, forKey: "includeWindowShadow") } }
    @Published var timerSeconds: Int { didSet { defaults.set(timerSeconds, forKey: "timerSeconds") } }
    @Published var fileNameTemplate: String { didSet { defaults.set(fileNameTemplate, forKey: "fileNameTemplate") } }
    @Published var saveDirectory: URL { didSet { defaults.set(saveDirectory.path, forKey: "saveDirectory") } }

    /// Last region in global capture coordinates, for "Capture Previous Area".
    var previousArea: CGRect? {
        get { defaults.string(forKey: "previousArea").map { NSRectFromString($0) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue.map { NSStringFromRect($0) }, forKey: "previousArea") }
    }

    private init() {
        defaults.register(defaults: ["includeWindowShadow": true, "timerSeconds": 5])
        hideDesktopIcons = defaults.bool(forKey: "hideDesktopIcons")
        includeWindowShadow = defaults.bool(forKey: "includeWindowShadow")
        timerSeconds = defaults.integer(forKey: "timerSeconds")
        fileNameTemplate = defaults.string(forKey: "fileNameTemplate") ?? defaultFileNameTemplate()
        saveDirectory = defaults.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0) }
            ?? ImageExporter.defaultDirectory
    }

    var captureOptions: CaptureOptions {
        CaptureOptions(hideDesktopIcons: hideDesktopIcons, includeWindowShadow: includeWindowShadow)
    }
}
