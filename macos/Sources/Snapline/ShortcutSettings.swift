import AppKit
import Carbon
import SwiftUI

@MainActor
final class ShortcutController: ObservableObject {
    static let shared = ShortcutController()
    @Published private(set) var shortcut = Settings.current.revealShortcut
    @Published private(set) var registered = false
    @Published private(set) var message = ""
    @Published private(set) var hasError = false
    var onAction: (() -> Void)?
    private var hotKey: HotKey?

    func activate() {
        let saved = Settings.current.revealShortcut
        let candidate = HotKey(shortcut: saved) { [weak self] in self?.onAction?() }
        hotKey = candidate
        shortcut = saved
        registered = candidate.isRegistered
        hasError = !registered
        message = registered ? L("Shortcut is ready. Try it in your usual apps.") : L("This shortcut is unavailable. Choose another combination below.")
    }

    @discardableResult
    func change(to value: KeyboardShortcut) -> Bool {
        guard value.isValid else {
            hasError = true
            message = L("Use Control or Option with another modifier and a letter or number. Standard editing shortcuts and Space are reserved.")
            return false
        }
        if value == shortcut && registered {
            hasError = false
            message = L("Shortcut is ready. Try it in your usual apps.")
            return true
        }
        let candidate = HotKey(shortcut: value) { [weak self] in self?.onAction?() }
        guard candidate.isRegistered else {
            hasError = true
            message = L("That shortcut is already in use or cannot be registered. Your previous shortcut is unchanged.")
            return false
        }
        hotKey = candidate // Replace only after registration succeeds.
        shortcut = value
        registered = true
        hasError = false
        Settings.current.keyboardShortcut = value
        Settings.save()
        message = L("Shortcut is ready. Try it in your usual apps.")
        NotificationCenter.default.post(name: .snaplineShortcutChanged, object: nil)
        return true
    }
}

extension Notification.Name {
    static let snaplineShortcutChanged = Notification.Name("snaplineShortcutChanged")
}

struct ShortcutPreferencesView: View {
    @ObservedObject private var controller = ShortcutController.shared
    @State private var manualKey = "L"
    @State private var manualModifiers = controlKey | cmdKey
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Show or hide the line"))
                Spacer()
                Text(controller.shortcut.label).font(.system(.body, design: .monospaced).bold())
                ShortcutRecorder { _ = controller.change(to: $0) }.frame(width: 140, height: 28)
            }
            Text(controller.message).font(.caption).foregroundStyle(controller.hasError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Restore recommended shortcut")) { controller.change(to: .standard) }
                .font(.caption)
            DisclosureGroup(L("Set the combination manually")) {
                HStack {
                    Picker(L("Modifier keys"), selection: $manualModifiers) {
                        Text("⌃⌘").tag(controlKey | cmdKey)
                        Text("⌃⇧⌘").tag(controlKey | shiftKey | cmdKey)
                        Text("⌥⇧⌘").tag(optionKey | shiftKey | cmdKey)
                    }.frame(width: 190)
                    TextField(L("Letter"), text: $manualKey).frame(width: 50).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L("Shortcut letter"))
                    Button(L("Apply shortcut")) {
                        if let value = KeyboardShortcut.named(manualKey, modifiers: manualModifiers) { controller.change(to: value) }
                    }.disabled(KeyboardShortcut.named(manualKey, modifiers: manualModifiers) == nil)
                }
                Text(L("Use this if another app intercepts the keys while recording."))
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (KeyboardShortcut) -> Void
    func makeNSView(context: Context) -> RecordShortcutButton {
        let button = RecordShortcutButton()
        button.onRecord = onRecord
        return button
    }
    func updateNSView(_ view: RecordShortcutButton, context: Context) { view.onRecord = onRecord }
}

final class RecordShortcutButton: NSButton {
    var onRecord: ((KeyboardShortcut) -> Void)?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = L("Change shortcut…")
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel(L("Change shortcut…"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        recording = true
        title = L("Press shortcut…")
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) { record(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }
    override func resignFirstResponder() -> Bool {
        recording = false
        title = L("Change shortcut…")
        return super.resignFirstResponder()
    }
    private func record(_ event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 { recording = false; title = L("Change shortcut…"); return }
        if let shortcut = KeyboardShortcut.from(event) {
            recording = false
            title = L("Change shortcut…")
            onRecord?(shortcut)
        } else {
            title = L("Try another shortcut")
            toolTip = L("Use Control or Option with another modifier and a letter or number. Standard editing shortcuts and Space are reserved.")
        }
    }
}
