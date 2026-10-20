import Carbon
import XCTest
@testable import Snapline

final class HotKeyRegistrationTests: XCTestCase {
    @MainActor
    func testNativeRegistrationDetectsConflictAndRoutesOnlyItsOwnEvent() throws {
        // A rare test-only chord; events are sent inside this test process,
        // never synthesized as keyboard input on the user's desktop.
        let shortcut = KeyboardShortcut(keyCode: kVK_F19, modifiers: cmdKey | controlKey | shiftKey, key: "F19")
        var delivered = 0
        let owner = HotKey(shortcut: shortcut) { delivered += 1 }
        XCTAssertTrue(owner.isRegistered)
        let conflicting = HotKey(shortcut: shortcut) { XCTFail("A conflicting registration must not replace the owner") }
        XCTAssertFalse(conflicting.isRegistered)

        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0, &event), noErr)
        let nativeEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(nativeEvent) }
        var identifier = owner.identifier
        XCTAssertEqual(SetEventParameter(nativeEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(nativeEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(delivered, 1)
        identifier.id += 1000
        XCTAssertEqual(SetEventParameter(nativeEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        _ = SendEventToEventTarget(nativeEvent, GetApplicationEventTarget())
        XCTAssertEqual(delivered, 1, "Other global shortcuts must never invoke this handler")
    }
    @MainActor
    func testChangingShortcutsKeepsThePreviousRegistrationWhenAChoiceConflicts() throws {
        let original = Settings.current
        let readOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        defer { Settings.current = original; Settings.readOnly = readOnly }
        var available: [KeyboardShortcut] = []
        for letter in ["J", "K", "L", "M", "N", "P", "R", "S", "U", "Z"] {
            let value = try XCTUnwrap(KeyboardShortcut.named(letter, modifiers: controlKey | cmdKey | shiftKey))
            let probe = HotKey(shortcut: value) {}
            if probe.isRegistered { available.append(value) }
            if available.count == 2 { break }
        }
        XCTAssertEqual(available.count, 2)
        guard available.count == 2 else { return }
        Settings.current.keyboardShortcut = available[0]
        let controller = ShortcutController()
        controller.activate()
        XCTAssertTrue(controller.registered)
        var collisionOwner: HotKey? = HotKey(shortcut: available[1]) {}
        XCTAssertTrue(collisionOwner?.isRegistered == true)
        XCTAssertFalse(controller.change(to: available[1]))
        XCTAssertTrue(controller.hasError)
        XCTAssertEqual(controller.shortcut, available[0])
        XCTAssertEqual(Settings.current.keyboardShortcut, available[0])
        do {
            let check = HotKey(shortcut: available[0]) {}
            XCTAssertFalse(check.isRegistered, "The original native shortcut must still belong to the controller")
        }
        collisionOwner = nil
        XCTAssertTrue(controller.change(to: available[1]))
        XCTAssertFalse(controller.hasError)
        XCTAssertEqual(controller.shortcut, available[1])
        XCTAssertEqual(Settings.current.keyboardShortcut, available[1])
        let oldKey = HotKey(shortcut: available[0]) {}
        XCTAssertTrue(oldKey.isRegistered, "A successful replacement releases the old combination")
    }

}
