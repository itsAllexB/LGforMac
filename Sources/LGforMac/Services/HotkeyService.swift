import AppKit
import Carbon.HIToolbox

enum HotkeyAction {
    case brightnessUp, brightnessDown
}

/// Registers global brightness hotkeys (default Control+Option+Up / Down) via Carbon's
/// RegisterEventHotKey — works without accessibility permissions and fires even when the
/// app is in the background. Events arrive on the main thread.
///
/// The modifier bitmask matches LGforWin's persisted format:
/// 1 = Option (Alt), 2 = Control (Ctrl), 4 = Shift, 8 = Command (Win).
final class HotkeyService {
    private static let idUp: UInt32 = 1
    private static let idDown: UInt32 = 2
    private static let signature: OSType = 0x4C47_464D // 'LGFM'

    private var hotkeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    var onHotkey: ((HotkeyAction) -> Void)?

    /// Starts listening, registering the arrow keys with the given modifier bitmask.
    func start(modifiers: Int) {
        installHandler()
        register(modifiers: modifiers)
    }

    /// Re-registers the hotkeys with a new modifier bitmask.
    func update(modifiers: Int) {
        unregister()
        register(modifiers: modifiers)
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
            service.onHotkey?(hotkeyID.id == HotkeyService.idUp ? .brightnessUp : .brightnessDown)
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
    }

    // (Re)registers the two hotkeys. Never registers bare arrow keys (modifiers == 0) —
    // that would swallow every arrow press system-wide.
    private func register(modifiers: Int) {
        guard modifiers != 0 else { return }
        var carbonMods: UInt32 = 0
        if modifiers & 1 != 0 { carbonMods |= UInt32(optionKey) }
        if modifiers & 2 != 0 { carbonMods |= UInt32(controlKey) }
        if modifiers & 4 != 0 { carbonMods |= UInt32(shiftKey) }
        if modifiers & 8 != 0 { carbonMods |= UInt32(cmdKey) }

        for (id, keyCode) in [(Self.idUp, UInt32(kVK_UpArrow)), (Self.idDown, UInt32(kVK_DownArrow))] {
            var ref: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: Self.signature, id: id)
            RegisterEventHotKey(keyCode, carbonMods, hotkeyID, GetApplicationEventTarget(), 0, &ref)
            if let ref { hotkeyRefs.append(ref) }
        }
    }

    private func unregister() {
        for ref in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
    }

    func dispose() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
