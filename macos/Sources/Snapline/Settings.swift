import Foundation

/// Everything the app remembers, as one JSON file in Application Support,
/// the same shape as the Windows app's settings.
struct Settings: Codable {
    var pegged: [String] = []
    var pinnedPaths: [String] = []
    /// Where each photo hangs, as a fraction of the width of the screen, by file path.
    var spots: [String: Double] = [:]
    /// Sticky notes, by the path of the picture each is drawn into.
    var notes: [String: NoteData] = [:]
    /// Stable across launches, unlike the in-memory card UUID.
    var recentCopyPath: String? = nil
    var soundOn = true
    var catchClipboard = false
    /// Optional so settings written by the original app still decode.
    var catchClipboardText: Bool? = nil
    var autoHangCopiedText: Bool {
        get { catchClipboardText ?? true }
        set { catchClipboardText = newValue }
    }
    var stayDownWhileUnused = false
    var takeDownAfterDrag = false
    /// Optional backing value lets older settings decode without this preference.
    var fullScreenOverlay: Bool? = nil
    var showOverFullScreen: Bool {
        get { fullScreenOverlay ?? false }
        set { fullScreenOverlay = newValue }
    }
    var autoArrange = false
    /// How far below the menu bar the line hangs, in points.
    var lineOffset: Double = 0
    /// A preset name like "bronze", or a hex colour like "#8C5A2E".
    var ropeColor = "bronze"
    /// wood, metal, mixed, red, blue, green or yellow.
    var pegStyle = "wood"
    var bows = true
    /// auto, light or dark.
    var appearance = "auto"
    /// auto, en or ar.
    var language = "auto"
    var welcomed = false

    struct NoteData: Codable {
        var text = ""
        var color = "yellow"
    }

    // MARK: Storage

    static let folder: URL = {
        #if DEBUG
        if let path = Bundle.main.object(forInfoDictionaryKey: "SnaplineDiagnosticDataDirectory") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Snapline", isDirectory: true)
    }()

    private static let file = folder.appendingPathComponent("settings.json")

    /// True while rendering art: the real settings file is left alone.
    nonisolated(unsafe) static var readOnly = false

    nonisolated(unsafe) static var current: Settings = load()

    private static func load() -> Settings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            // The first version kept a few things in UserDefaults.
            var s = Settings()
            s.pegged = UserDefaults.standard.stringArray(forKey: "pegged") ?? []
            s.soundOn = !UserDefaults.standard.bool(forKey: "soundOff")
            s.welcomed = UserDefaults.standard.bool(forKey: "welcomed")
            return s
        }
        return settings
    }

    static func save() {
        if readOnly { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(current)
            try data.write(to: file, options: .atomic)
        } catch {
            log.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
