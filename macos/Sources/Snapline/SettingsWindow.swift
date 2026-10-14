import AppKit
import SwiftUI

extension Notification.Name {
    static let snaplineSettingsChanged = Notification.Name("snaplineSettingsChanged")
}

/// Everything you can change, on one page. Changes apply as you make them.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Snapline · \(L("Settings"))"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: SettingsView())
        w.center()
        window = w
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window = nil
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// After a language change the page is rebuilt in place.
    static func rebuild() {
        guard let w = window else { return }
        w.title = "Snapline · \(L("Settings"))"
        w.contentViewController = NSHostingController(rootView: SettingsView())
    }
}

struct SettingsView: View {
    @State private var s = Settings.current
    @State private var startsAtLogin = AppDelegate.launchesAtLogin

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    if let mark = Brand.mark { Image(nsImage: mark).resizable().frame(width: 34, height: 34) }
                    Text("Snapline").font(.system(size: 24, weight: .heavy))
                }
                .padding(.bottom, 4)
            }
            Section(L("The line")) {
                Toggle(L("Stay down until each capture is used"), isOn: $s.stayDownWhileUnused)
                Toggle(L("Take down after dragging into an app"), isOn: $s.takeDownAfterDrag)
                Toggle("在全屏应用上显示 / Show over full screen apps", isOn: $s.showOverFullScreen)
                Toggle(L("Arrange photos evenly along the line"), isOn: $s.autoArrange)
                HStack {
                    Text(L("Distance from the top of the screen"))
                    Spacer()
                    TextField("", value: $s.lineOffset, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                }
            }
            Section(L("Look")) {
                Picker(L("Line colour"), selection: $s.ropeColor) {
                    ForEach(Pegs.ropeColors, id: \.self) { key in
                        HStack { Circle().fill(Pegs.ropeColor(key)).frame(width: 12, height: 12); Text(L(Pegs.colorName(key))) }.tag(key)
                    }
                }
                Picker(L("Clothespins"), selection: $s.pegStyle) {
                    ForEach(Pegs.styles, id: \.self) { key in Text(L(Pegs.pegName(key))).tag(key) }
                }
                Toggle(L("Bows at the ends of the line"), isOn: $s.bows)
                Picker(L("Appearance"), selection: $s.appearance) {
                    Text(L("Follow macOS")).tag("auto"); Text(L("Light")).tag("light"); Text(L("Dark")).tag("dark")
                }
                Picker(L("Language"), selection: $s.language) {
                    Text(L("Follow macOS")).tag("auto"); Text("English").tag("en"); Text("العربية").tag("ar")
                }
            }
            Section(L("Captures")) {
                Toggle("复制文字自动挂上 / Auto-hang copied text", isOn: $s.autoHangCopiedText)
                Toggle(L("Catch clipboard captures"), isOn: $s.catchClipboard)
                Toggle(L("Handle screenshots"), isOn: Binding(get: { Inbox.isEnabled }, set: { on in
                    NotificationCenter.default.post(name: .snaplineInboxToggle, object: on)
                }))
                HStack {
                    Text(L("Caught captures are saved to"))
                    Spacer()
                    Text(Inbox.folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section(L("General")) {
                Toggle(L("Sounds"), isOn: $s.soundOn)
                Toggle(L("Open at login"), isOn: $startsAtLogin)
                    .onChange(of: startsAtLogin) { _, on in AppDelegate.setLaunchesAtLogin(on) }
            }
            Text(String(format: L("Changes apply right away. Everything lives in %@."), Settings.folder.path))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .environment(\.layoutDirection, Localization.isRTL ? .rightToLeft : .leftToRight)
        .onChange(of: s.stayDownWhileUnused) { _, _ in apply() }
        .onChange(of: s.takeDownAfterDrag) { _, _ in apply() }
        .onChange(of: s.showOverFullScreen) { _, _ in apply() }
        .onChange(of: s.autoArrange) { _, _ in apply() }
        .onChange(of: s.lineOffset) { _, _ in apply() }
        .onChange(of: s.ropeColor) { _, _ in apply() }
        .onChange(of: s.pegStyle) { _, _ in apply() }
        .onChange(of: s.bows) { _, _ in apply() }
        .onChange(of: s.appearance) { _, _ in apply() }
        .onChange(of: s.language) { _, _ in apply(); DispatchQueue.main.async { SettingsWindow.rebuild() } }
        .onChange(of: s.catchClipboard) { _, _ in apply() }
        .onChange(of: s.autoHangCopiedText) { _, _ in apply() }
        .onChange(of: s.soundOn) { _, _ in apply() }
    }

    private func apply() {
        // Captures and note edits may arrive while this window is open.
        // Applying a preference must not replace those newer live records.
        var updated = s
        let live = Settings.current
        updated.pegged = live.pegged
        updated.pinnedPaths = live.pinnedPaths
        updated.spots = live.spots
        updated.notes = live.notes
        Settings.current = updated
        Settings.save()
        Localization.refresh()
        NotificationCenter.default.post(name: .snaplineSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let snaplineInboxToggle = Notification.Name("snaplineInboxToggle")
}

extension Pegs {
    static func colorName(_ key: String) -> String {
        switch key {
        case "gray": return "Gray"
        case "black": return "Black"
        case "white": return "White"
        case "red": return "Red"
        case "blue": return "Blue"
        case "green": return "Green"
        case "gold": return "Gold"
        case "pink": return "Pink"
        case "purple": return "Purple"
        default: return "Bronze"
        }
    }

    static func pegName(_ key: String) -> String {
        switch key {
        case "metal": return "Aluminium"
        case "mixed": return "Coloured plastic, mixed"
        case "red": return "Red plastic"
        case "blue": return "Blue plastic"
        case "green": return "Green plastic"
        case "yellow": return "Yellow plastic"
        default: return "Wooden"
        }
    }
}

/// The mark, loaded from the app bundle for the Settings header.
enum Brand {
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Mark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
