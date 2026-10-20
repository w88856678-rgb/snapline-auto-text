import AppKit
import Carbon

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    static let standard = KeyboardShortcut(keyCode: kVK_ANSI_L, modifiers: controlKey | cmdKey, key: "L")
    static let modifierMask = controlKey | optionKey | shiftKey | cmdKey
    static let letterCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
        "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
        "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
        "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    ]
    static func named(_ key: String, modifiers: Int) -> KeyboardShortcut? {
        let letter = key.uppercased()
        guard let code = letterCodes[letter] else { return nil }
        let value = KeyboardShortcut(keyCode: code, modifiers: modifiers, key: letter)
        return value.isValid ? value : nil
    }

    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key.uppercased()
    }
    var flags: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { value.insert(.control) }
        if modifiers & optionKey != 0 { value.insert(.option) }
        if modifiers & shiftKey != 0 { value.insert(.shift) }
        if modifiers & cmdKey != 0 { value.insert(.command) }
        return value
    }
    var isValid: Bool {
        guard (0...127).contains(keyCode), !key.isEmpty,
              modifiers & ~Self.modifierMask == 0,
              modifiers & (cmdKey | controlKey | optionKey) != 0,
              modifiers.nonzeroBitCount >= 2 else { return false }
        let prohibited = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
                          kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
                          kVK_CapsLock, kVK_Escape, kVK_Delete, kVK_ForwardDelete,
                          kVK_Return, kVK_Tab]
        if prohibited.contains(keyCode) { return false }
        if keyCode == kVK_Space { return false } // Spotlight, input methods, emoji.
        // Never take over common editing, window, or application commands.
        if modifiers == cmdKey || modifiers == cmdKey | shiftKey {
            return false
        }
        // VoiceOver's modifier and familiar system/document shortcuts stay free.
        if modifiers & (controlKey | optionKey) == (controlKey | optionKey) { return false }
        let reserved: [Int: Set<Int>] = [
            cmdKey | controlKey: [kVK_ANSI_Q, kVK_ANSI_F, kVK_ANSI_D, kVK_ANSI_V],
            cmdKey | optionKey: [kVK_ANSI_V, kVK_ANSI_C, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_W, kVK_ANSI_L, kVK_ANSI_N],
            cmdKey | optionKey | shiftKey: [kVK_ANSI_V],
        ]
        if reserved[modifiers]?.contains(keyCode) == true { return false }
        return key.count == 1 && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    static func from(_ event: NSEvent) -> KeyboardShortcut? {
        var mods = 0
        if event.modifierFlags.contains(.control) { mods |= controlKey }
        if event.modifierFlags.contains(.option) { mods |= optionKey }
        if event.modifierFlags.contains(.shift) { mods |= shiftKey }
        if event.modifierFlags.contains(.command) { mods |= cmdKey }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = KeyboardShortcut(keyCode: Int(event.keyCode), modifiers: mods, key: key)
        return shortcut.isValid ? shortcut : nil
    }
}

/// A user-controlled session: copies and pointer movement cannot open it.
struct QuietRevealState {
    private(set) var isOpen = false
    private(set) var isManual = false
    private(set) var unseenIDs = Set<UUID>()

    mutating func capture(_ id: UUID, liveIDs: Set<UUID>) {
        unseenIDs.formIntersection(liveIDs)
        if !isOpen { unseenIDs.insert(id) }
    }
    mutating func open(manually: Bool) {
        isOpen = true
        isManual = manually
        unseenIDs.removeAll()
    }
    mutating func hover(enabled: Bool) {
        if enabled && !isOpen { open(manually: false) }
    }
    mutating func close(interacting: Bool = false) {
        guard !interacting else { return }
        isOpen = false
        isManual = false
    }
}
