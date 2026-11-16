import AppKit
import Carbon.HIToolbox
import STTproCore

/// System-wide hotkeys via Carbon's RegisterEventHotKey. It reports both
/// press and release (needed for push-to-talk) and, unlike a CGEvent tap,
/// needs no Accessibility or Input Monitoring permission.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct Handler {
        var onPress: () -> Void
        var onRelease: (() -> Void)?
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: Handler] = [:]
    private var bindings: [UInt32: HotkeyBinding] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false
    private static let signature: OSType = 0x5354_5470 // 'STTp'

    /// Hotkeys that could not be registered (taken by macOS or another app).
    private(set) var failed: [HotkeyBinding] = []

    private init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotkeyManager.shared.dispatch(id: id, pressed: pressed) }
            return noErr
        }, specs.count, &specs, nil, &eventHandler)
        if status != noErr { Log.error("InstallEventHandler failed: \(status)") }
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard !suspended, let h = handlers[id] else { return }
        if pressed { h.onPress() } else { h.onRelease?() }
    }

    @discardableResult
    func register(id: UInt32, binding: HotkeyBinding, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error("Could not register hotkey \(binding.displayName) (status \(status))")
            failed.append(binding)
            return false
        }
        refs[id] = ref
        handlers[id] = Handler(onPress: onPress, onRelease: onRelease)
        bindings[id] = binding
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
        bindings[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
        failed.removeAll()
    }

    /// Temporarily unregister everything (while the user records a new shortcut),
    /// so the key combination reaches the recorder instead of firing.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for ref in refs.values { UnregisterEventHotKey(ref) }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        let saved = bindings
        let savedHandlers = handlers
        refs.removeAll()
        for (id, binding) in saved {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[id] = ref } else { handlers[id] = nil }
        }
        _ = savedHandlers
    }
}

/// Detects when a hotkey collides with an enabled macOS keyboard shortcut,
/// most commonly ⌃Space = "Select the previous input source", which many
/// bilingual (e.g. Hebrew/English) setups use.
enum SystemShortcutConflicts {
    /// Symbolic hotkey IDs: 60 = previous input source, 61 = next input source,
    /// 64 = Spotlight, 65 = Finder search window.
    private static let names: [Int: String] = [
        60: "Select the previous input source",
        61: "Select next source in Input menu",
        64: "Show Spotlight search",
        65: "Show Finder search window",
    ]

    static func conflict(for binding: HotkeyBinding) -> String? {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let all = defaults.dictionary(forKey: "AppleSymbolicHotKeys") else { return nil }
        for (id, name) in names {
            guard let entry = all[String(id)] as? [String: Any],
                  (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Int], params.count >= 3 else { continue }
            if UInt32(params[1]) == binding.keyCode && carbonModifiers(fromCocoa: params[2]) == binding.modifiers {
                return name
            }
        }
        return nil
    }

    static func carbonModifiers(fromCocoa raw: Int) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(raw))
        return carbonModifiers(flags)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= CarbonModifiers.command }
        if flags.contains(.shift) { m |= CarbonModifiers.shift }
        if flags.contains(.option) { m |= CarbonModifiers.option }
        if flags.contains(.control) { m |= CarbonModifiers.control }
        return m
    }
}
