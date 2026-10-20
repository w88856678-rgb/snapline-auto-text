import Carbon

/// Registered global shortcut; no Accessibility permission or silent fallback.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    let identifier: EventHotKeyID
    private static var serial: UInt32 = 0
    private(set) var status: OSStatus = noErr
    var isRegistered: Bool { status == noErr && ref != nil }

    init(shortcut: KeyboardShortcut, action: @escaping () -> Void) {
        self.action = action
        Self.serial += 1
        identifier = EventHotKeyID(signature: OSType(0x534E_4150), id: Self.serial)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var received = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &received)
            guard result == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                guard received.signature == owner.identifier.signature, received.id == owner.identifier.id else {
                    return OSStatus(eventNotHandledErr)
                }
                owner.action()
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { status = installed; return }
        status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), identifier,
                                    GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
