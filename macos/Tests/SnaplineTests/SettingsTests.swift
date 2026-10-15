import Foundation
import XCTest
@testable import Snapline

final class SettingsTests: XCTestCase {
    func testNewInstallEnablesImagesAndExistingImageChoiceIsPreserved() throws {
        XCTAssertTrue(Settings().catchClipboard)
        var settings = Settings()
        settings.catchClipboard = false
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.catchClipboard)
        XCTAssertTrue(decoded.autoHangCopiedText)
    }

    func testLegacySettingsKeepExistingContentAndEnableCopiedTextByDefault() throws {
        var original = Settings()
        original.pegged = ["/tmp/existing-screenshot.png", "/tmp/existing-note.png"]
        original.notes = ["/tmp/existing-note.png": .init(text: "已有便签 🧺\n第二行", color: "green")]
        original.catchClipboard = true
        original.autoHangCopiedText = true
        let encoded = try JSONEncoder().encode(original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(legacy.removeValue(forKey: "catchClipboardText"))
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)

        let restored = try JSONDecoder().decode(Settings.self, from: legacyData)
        XCTAssertEqual(restored.pegged, original.pegged)
        XCTAssertEqual(restored.notes.keys.sorted(), original.notes.keys.sorted())
        XCTAssertEqual(restored.notes["/tmp/existing-note.png"]?.text, "已有便签 🧺\n第二行")
        XCTAssertEqual(restored.notes["/tmp/existing-note.png"]?.color, "green")
        XCTAssertTrue(restored.catchClipboard)
        XCTAssertNil(restored.catchClipboardText)
        XCTAssertTrue(restored.autoHangCopiedText)
    }

    func testExplicitlyDisablingCopiedTextSurvivesSettingsRoundTrip() throws {
        var settings = Settings()
        settings.autoHangCopiedText = false
        settings.catchClipboard = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.catchClipboardText, false)
        XCTAssertFalse(decoded.autoHangCopiedText)
        XCTAssertTrue(decoded.catchClipboard, "Text and image capture preferences remain independent")
    }
}
