import Carbon.HIToolbox
import OSLog

/// Global shortcuts via Carbon `RegisterEventHotKey` (needs no Accessibility
/// permission). Every shortcut dispatches the same action as its menu item.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Shortcut: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
        let display: String
    }

    enum RegistrationError: Error {
        case conflict(String)
        case failed(String, OSStatus)
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private let log = Logger(subsystem: "com.snapora.app", category: "hotkeys")

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) throws {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_5052) /* 'SNPR' */, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("hotkey \(shortcut.display, privacy: .public) failed: \(status)")
            if status == eventHotKeyExistsErr { throw RegistrationError.conflict(shortcut.display) }
            throw RegistrationError.failed(shortcut.display, status)
        }
        refs[id] = ref
        actions[id] = action
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension HotKeyCenter.Shortcut {
    private static let optShift = UInt32(optionKey | shiftKey)

    // Defaults avoid the system's ⌘⇧3/4/5 screenshot shortcuts.
    static let allInOne = Self(keyCode: UInt32(kVK_ANSI_1), modifiers: optShift, display: "⌥⇧1")
    static let window = Self(keyCode: UInt32(kVK_ANSI_2), modifiers: optShift, display: "⌥⇧2")
    static let fullscreen = Self(keyCode: UInt32(kVK_ANSI_3), modifiers: optShift, display: "⌥⇧3")
    static let region = Self(keyCode: UInt32(kVK_ANSI_4), modifiers: optShift, display: "⌥⇧4")
    static let recording = Self(keyCode: UInt32(kVK_ANSI_5), modifiers: optShift, display: "⌥⇧5")
    static let previousArea = Self(keyCode: UInt32(kVK_ANSI_6), modifiers: optShift, display: "⌥⇧6")
    static let ocr = Self(keyCode: UInt32(kVK_ANSI_O), modifiers: optShift, display: "⌥⇧O")
}
