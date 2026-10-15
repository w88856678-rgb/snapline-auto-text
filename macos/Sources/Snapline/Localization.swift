import Foundation

/// Looks up text in `Resources/<language>.lproj/Localizable.strings`, keyed by
/// the English text itself. The language follows the system, or the one
/// chosen in Settings, and anything missing falls back to English.
///
/// The folders are copied into the app by `scripts/build-app.sh`. Running the
/// bare binary, outside the app, shows English.
func L(_ english: String) -> String {
    Localization.text(english)
}

enum Localization {
    /// "en", "ar", or "zh-Hans".
    nonisolated(unsafe) static var language: String = resolve()
    static var isRTL: Bool { language == "ar" }

    nonisolated(unsafe) private static var table: [String: String]? = nil

    static func refresh() {
        language = resolve()
        table = nil
    }

    private static func resolve() -> String {
        resolve(chosen: Settings.current.language, preferredLanguages: Locale.preferredLanguages)
    }

    /// Kept separate from saved preferences so language matching can be
    /// checked without reading or changing the user's settings.
    static func resolve(chosen: String, preferredLanguages: [String]) -> String {
        if ["en", "ar", "zh-Hans"].contains(chosen) { return chosen }
        for preferred in preferredLanguages {
            let base = preferred.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").first
            switch base {
            case "zh": return "zh-Hans"
            case "ar": return "ar"
            case "en": return "en"
            default: continue
            }
        }
        return "en"
    }

    static func text(_ english: String) -> String {
        if language == "en" { return english }
        if table == nil { table = load(language) }
        return table?[english] ?? english
    }

    private static func load(_ lang: String) -> [String: String] {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(lang).lproj"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
        return dict
    }
}
