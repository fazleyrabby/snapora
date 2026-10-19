@preconcurrency import AVFoundation

/// Audio input devices available for recording.
enum Microphones {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static func available() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var systemDefault: Device? {
        AVCaptureDevice.default(for: .audio).map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The device to use for `id`, falling back to the system default when it
    /// is empty or no longer connected.
    static func resolve(_ id: String?) -> AVCaptureDevice? {
        if let id, !id.isEmpty, let device = AVCaptureDevice(uniqueID: id) { return device }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Display name for the menu: the chosen device, or the default's name.
    static func name(for id: String) -> String {
        if !id.isEmpty, let d = available().first(where: { $0.id == id }) { return d.name }
        return systemDefault.map { "Default (\($0.name))" } ?? "Default"
    }
}
