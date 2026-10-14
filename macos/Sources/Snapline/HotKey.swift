import Carbon

/// A single global shortcut through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private(set) var usesFallback = false
    private static var action: (() -> Void)?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5445_4E44), id: 1) // "TEND"
        let result = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if result != noErr {
            // Tendedero uses the same shortcut. Keep both apps usable without
            // asking the user to quit one just to reveal this line.
            ref = nil
            usesFallback = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers | shiftKey), id,
                                              GetApplicationEventTarget(), 0, &ref) == noErr
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
