import AppKit
import Carbon
import XCTest
@testable import Snapline

final class KeyboardShortcutTests: XCTestCase {
    func testRecommendedShortcutAndDisplayAgree() throws {
        let shortcut = KeyboardShortcut.standard
        XCTAssertTrue(shortcut.isValid)
        XCTAssertEqual(shortcut.keyCode, kVK_ANSI_L)
        XCTAssertEqual(shortcut.label, "⌃⌘L")
        XCTAssertTrue(shortcut.flags.contains(.control))
        XCTAssertTrue(shortcut.flags.contains(.command))
        XCTAssertFalse(shortcut.flags.contains(.option))
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded, shortcut)
        XCTAssertEqual(KeyboardShortcut.named("l", modifiers: controlKey | cmdKey), shortcut)
        XCTAssertNil(KeyboardShortcut.named("LL", modifiers: controlKey | cmdKey))
        XCTAssertNil(KeyboardShortcut.named("L", modifiers: cmdKey))
    }
    func testStandardEditingKeysInputMethodKeysAndBareKeysAreRejected() {
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_Z] {
            XCTAssertFalse(KeyboardShortcut(keyCode: key, modifiers: cmdKey, key: "V").isValid)
            XCTAssertFalse(KeyboardShortcut(keyCode: key, modifiers: cmdKey | shiftKey, key: "V").isValid)
        }
        for key in [kVK_Space, kVK_Tab, kVK_Escape, kVK_Return, kVK_Control, kVK_Command] {
            XCTAssertFalse(KeyboardShortcut(keyCode: key, modifiers: cmdKey | controlKey, key: "L").isValid)
        }
        XCTAssertFalse(KeyboardShortcut(keyCode: kVK_ANSI_L, modifiers: 0, key: "L").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: kVK_ANSI_L, modifiers: controlKey, key: "L").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey | shiftKey, key: "V").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: kVK_ANSI_Q, modifiers: cmdKey | controlKey, key: "Q").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey, key: "T").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: -1, modifiers: cmdKey | controlKey, key: "L").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 999, modifiers: cmdKey | controlKey, key: "L").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: kVK_ANSI_L, modifiers: 1 << 24, key: "L").isValid)
    }
    @MainActor
    func testRecordingARealNSEventKeepsTheKeyCodeAndModifiers() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command, .shift],
                                                  timestamp: 0, windowNumber: 0, context: nil, characters: "L",
                                                  charactersIgnoringModifiers: "L", isARepeat: false, keyCode: UInt16(kVK_ANSI_L)))
        let result = try XCTUnwrap(KeyboardShortcut.from(event))
        XCTAssertEqual(result.keyCode, kVK_ANSI_L)
        XCTAssertEqual(result.modifiers, controlKey | cmdKey | shiftKey)
        XCTAssertEqual(result.label, "⌃⇧⌘L")
    }
    func testOldSettingsMigrateToQuietModeWithoutLosingContent() throws {
        var original = Settings()
        original.pegged = ["/tmp/retained.png", "/tmp/retained-note.png"]
        original.pinnedPaths = ["/tmp/retained-note.png"]
        original.notes = ["/tmp/retained-note.png": .init(text: "保留全文\n第二行 🧺", color: "pink")]
        original.recentCopyPath = "/tmp/retained-note.png"
        original.stayDownWhileUnused = true
        original.keyboardShortcut = .standard
        original.hoverRevealEnabled = true
        original.quietOnboardingVersion = 1
        original.shortcutPracticed = true
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["keyboardShortcut", "hoverToReveal", "quietOnboardingVersion", "shortcutPracticed"] { legacy.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(restored.hoverRevealEnabled)
        XCTAssertEqual(restored.revealShortcut, .standard)
        XCTAssertNil(restored.quietOnboardingVersion)
        XCTAssertEqual(restored.pegged, original.pegged)
        XCTAssertEqual(restored.pinnedPaths, original.pinnedPaths)
        XCTAssertEqual(restored.notes["/tmp/retained-note.png"]?.text, "保留全文\n第二行 🧺")
        XCTAssertEqual(restored.recentCopyPath, original.recentCopyPath)
        XCTAssertTrue(restored.stayDownWhileUnused)
    }
    func testExplicitHoverChoiceAndCustomShortcutSurviveRelaunch() throws {
        var settings = Settings()
        settings.hoverRevealEnabled = true
        settings.keyboardShortcut = .init(keyCode: kVK_ANSI_K, modifiers: controlKey | cmdKey | shiftKey, key: "K")
        settings.quietOnboardingVersion = 1
        settings.shortcutPracticed = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.hoverRevealEnabled)
        XCTAssertEqual(decoded.revealShortcut, settings.keyboardShortcut)
        XCTAssertEqual(decoded.quietOnboardingVersion, 1)
        XCTAssertEqual(decoded.shortcutPracticed, true)
        settings.keyboardShortcut = .init(keyCode: -1, modifiers: 0, key: "")
        XCTAssertEqual(settings.revealShortcut, .standard)
    }
}
