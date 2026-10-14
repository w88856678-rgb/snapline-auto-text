import Foundation

/// Inbox mode: Snapline takes over where screenshots go.
///
/// It changes two macOS screenshot settings, the same ones in the Options
/// menu of Cmd+Shift+5: the floating thumbnail is turned off, so the file is
/// written at once instead of five seconds later, and the save location
/// becomes Snapline's own folder, so the Desktop only gets what you keep.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching. If Snapline is ever force-quit, the next launch puts them
/// back before anything else, and the two commands in the README do the same
/// by hand.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    static let folder = Settings.folder.appendingPathComponent("Screenshots", isDirectory: true)

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    /// Whether macOS is currently sending screenshots to our folder.
    static var isApplied: Bool {
        guard let current = CFPreferencesCopyAppValue(locationKey, domain) as? String else { return false }
        return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }

    /// Whether a snapshot of the user's own settings is being held.
    private static var hasSaved: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    static func apply() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The user's values are saved once, the first time, and never replaced
        // by our own: a crash that left them applied must not lose the originals.
        if !hasSaved && !isApplied {
            let saved: [String: Any] = [
                "location": CFPreferencesCopyAppValue(locationKey, domain) as? String ?? NSNull(),
                "locationScreenshot": CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String ?? NSNull(),
                "thumbnail": CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool ?? NSNull(),
            ]
            UserDefaults.standard.set(saved.compactMapValues { $0 is NSNull ? nil : $0 }, forKey: savedKey)
        }
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(thumbnailKey, false)
    }

    /// Puts the user's settings back. Each one on its own: the location only
    /// if it still points at our folder (a location the user changed meanwhile
    /// is theirs to keep), the thumbnail always, since only we turn it off.
    static func restore() {
        guard hasSaved else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if isApplied {
            set(locationKey, saved["location"])
            set(screenshotLocationKey, saved["locationScreenshot"])
        }
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// At launch: a snapshot left over from a run that never got to restore
    /// (a crash, a force quit) is put back first, so the mode starts clean.
    static func recoverIfNeeded() {
        if hasSaved { restore() }
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
