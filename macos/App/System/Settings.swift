import Foundation

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case quickAccess, saveAndCopy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quickAccess: "Show Quick Access"
        case .saveAndCopy: "Save & Copy"
        }
    }
}

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

    @Published var afterCapture: AfterCaptureAction { didSet { defaults.set(afterCapture.rawValue, forKey: "afterCapture") } }
    /// Seconds before a Quick Access card closes itself; 0 = never.
    @Published var quickAccessAutoCloseSeconds: Int { didSet { defaults.set(quickAccessAutoCloseSeconds, forKey: "quickAccessAutoCloseSeconds") } }

    @Published var recordFPS: Int { didSet { defaults.set(recordFPS, forKey: "recordFPS") } }
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: "recordMicrophone") } }
    @Published var recordShowsCursor: Bool { didSet { defaults.set(recordShowsCursor, forKey: "recordShowsCursor") } }
    @Published var recordHEVC: Bool { didSet { defaults.set(recordHEVC, forKey: "recordHEVC") } }

    /// Last region in global capture coordinates, for "Capture Previous Area".
    var previousArea: CGRect? {
        get { defaults.string(forKey: "previousArea").map { NSRectFromString($0) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue.map { NSStringFromRect($0) }, forKey: "previousArea") }
    }

    private init() {
        defaults.register(defaults: [
            "includeWindowShadow": true, "timerSeconds": 5,
            "recordFPS": 60, "recordShowsCursor": true,
        ])
        hideDesktopIcons = defaults.bool(forKey: "hideDesktopIcons")
        includeWindowShadow = defaults.bool(forKey: "includeWindowShadow")
        timerSeconds = defaults.integer(forKey: "timerSeconds")
        fileNameTemplate = defaults.string(forKey: "fileNameTemplate") ?? defaultFileNameTemplate()
        afterCapture = defaults.string(forKey: "afterCapture").flatMap(AfterCaptureAction.init(rawValue:)) ?? .quickAccess
        quickAccessAutoCloseSeconds = defaults.integer(forKey: "quickAccessAutoCloseSeconds")
        recordFPS = defaults.integer(forKey: "recordFPS")
        recordSystemAudio = defaults.bool(forKey: "recordSystemAudio")
        recordMicrophone = defaults.bool(forKey: "recordMicrophone")
        recordShowsCursor = defaults.bool(forKey: "recordShowsCursor")
        recordHEVC = defaults.bool(forKey: "recordHEVC")
        saveDirectory = defaults.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0) }
            ?? ImageExporter.defaultDirectory
    }

    var captureOptions: CaptureOptions {
        CaptureOptions(hideDesktopIcons: hideDesktopIcons, includeWindowShadow: includeWindowShadow)
    }

    func recordingConfig(source: RecordingConfig.Source) -> RecordingConfig {
        RecordingConfig(
            source: source,
            framesPerSecond: recordFPS,
            showsCursor: recordShowsCursor,
            systemAudio: recordSystemAudio,
            microphone: recordMicrophone,
            codec: recordHEVC ? .hevc : .h264,
            hideDesktopIcons: hideDesktopIcons
        )
    }
}
