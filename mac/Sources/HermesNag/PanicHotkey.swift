import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey.
///
/// Carbon rather than `NSEvent.addGlobalMonitorForEvents` because it needs no
/// Accessibility permission — a hotkey that silently doesn't work until you
/// clear a TCC prompt isn't a hotkey. Multiple instances coexist: every
/// handler sees every hotkey press and acts only on its own signature.
///
/// Two registered today:
///   ⌃⌥⌘Esc  — panic (kill every window, pause 60m)
///   ⌃⌥Space — quick add (Spotlight-style capture)
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let onPress: () -> Void

    init(signature: String, keyCode: UInt32, modifiers: UInt32,
         onPress: @escaping () -> Void) {
        var sig: OSType = 0
        for byte in signature.utf8.prefix(4) { sig = (sig << 8) | OSType(byte) }
        self.signature = sig
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onPress = onPress
    }

    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()

            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressedID)

            // Every handler sees every hotkey press; act only on our own.
            let mySignature = MainActor.assumeIsolated { hotkey.signature }
            guard pressedID.signature == mySignature else { return noErr }

            DispatchQueue.main.async { MainActor.assumeIsolated { hotkey.onPress() } }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

// Convenience factories for the two app hotkeys.
extension GlobalHotkey {
    /// ⌃⌥⌘Esc — spec safety valve 3.
    static func panic(onPress: @escaping () -> Void) -> GlobalHotkey {
        GlobalHotkey(signature: "HNAG", keyCode: UInt32(kVK_Escape),
                     modifiers: UInt32(controlKey | optionKey | cmdKey),
                     onPress: onPress)
    }

    /// ⌃⌥Space — quick add. Deliberately NOT plain ⌥Space, which collides
    /// with Alfred/Raycast and types a non-breaking space in many apps.
    static func quickAdd(onPress: @escaping () -> Void) -> GlobalHotkey {
        GlobalHotkey(signature: "HNQA", keyCode: UInt32(kVK_Space),
                     modifiers: UInt32(controlKey | optionKey),
                     onPress: onPress)
    }
}
