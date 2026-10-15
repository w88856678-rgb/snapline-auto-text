import Foundation
import XCTest
@testable import Snapline

final class LocalizationTests: XCTestCase {
    func testExplicitLanguageChoiceOverridesSystemLanguages() {
        for language in ["en", "ar", "zh-Hans"] {
            XCTAssertEqual(Localization.resolve(chosen: language, preferredLanguages: ["fr-FR", "zh-Hans-CN"]), language)
        }
    }

    func testChineseSystemLocalesChooseSimplifiedChinese() {
        for locale in ["zh", "zh-CN", "zh-Hans-CN", "zh-Hans-SG", "zh-Hant-TW", "ZH_cn"] {
            XCTAssertEqual(Localization.resolve(chosen: "auto", preferredLanguages: [locale]), "zh-Hans")
        }
    }

    func testSystemPreferenceOrderAndUnsupportedLanguages() {
        XCTAssertEqual(Localization.resolve(chosen: "auto", preferredLanguages: ["fr-FR", "zh-Hans", "en-US"]), "zh-Hans")
        XCTAssertEqual(Localization.resolve(chosen: "auto", preferredLanguages: ["ar-SA", "zh-Hans"]), "ar")
        XCTAssertEqual(Localization.resolve(chosen: "auto", preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(Localization.resolve(chosen: "auto", preferredLanguages: ["fr-FR", "de-DE"]), "en")
        XCTAssertEqual(Localization.resolve(chosen: "unknown", preferredLanguages: []), "en")
    }

}
