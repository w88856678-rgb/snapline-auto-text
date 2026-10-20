import AppKit
import SwiftUI

struct ShortcutPractice {
    private(set) var isExpanded = false
    private(set) var hasOpened = false
    private(set) var isComplete = false
    mutating func toggle() {
        isExpanded.toggle()
        if isExpanded { hasOpened = true }
        else if hasOpened { isComplete = true }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var practice = ShortcutPractice()
    let isUpgrade: Bool
    init(isUpgrade: Bool) { self.isUpgrade = isUpgrade }
}

/// The practice card belongs only to this window: no real note, file, or
/// clipboard is created, and the 20-item workspace stays untouched.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?
    private static var model: OnboardingModel?
    static var isVisible: Bool { window?.isVisible == true }

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = OnboardingModel(isUpgrade: Settings.current.welcomed)
        let w = OnboardingHostWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 650),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Start using Snapline")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        w.center()
        self.model = model
        window = w
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                Settings.current.quietOnboardingVersion = 1
                Settings.current.welcomed = true
                Settings.current.shortcutPracticed = Settings.current.shortcutPracticed == true || model.practice.isComplete
                Settings.save()
                self.model = nil
                self.window = nil
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func handleShortcut() -> Bool {
        guard let window, window.isVisible, let model else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.practice.toggle()
        return true
    }
    static func close() { window?.close() }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var controller = ShortcutController.shared
    @State private var captureText = Settings.current.autoHangCopiedText
    @State private var captureImages = Settings.current.catchClipboard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 32)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Keep collecting. Open only when you need it.")).font(.title2.bold())
                    Text(L(model.isUpgrade ? "A quieter way to use your line" : "Welcome to Snapline")).foregroundStyle(.secondary)
                }
            }
            Text(L("Copied text and images are saved in the background. Moving to the top of the screen or copying will not open the line."))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Toggle(L("Auto-hang copied text"), isOn: $captureText)
                Toggle(L("Auto-hang copied images"), isOn: $captureImages)
            }.font(.callout)
            Divider()
            ShortcutPreferencesView()
            VStack(alignment: .leading, spacing: 10) {
                Text(model.practice.isComplete ? L("You are ready") : L("Try opening and closing the sample"))
                    .font(.headline)
                Text(String(format: L("Press %@ once to open the sample, then press it again to close."), controller.shortcut.label))
                    .font(.callout).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07))
                    if model.practice.isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Sample note")).font(.headline)
                            Text(L("Your copied text and pictures will be here when you need them."))
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        .padding(10)
                    } else {
                        Label(model.practice.isComplete ? L("Opened and closed successfully") : L("The sample is tucked away"),
                              systemImage: model.practice.isComplete ? "checkmark.circle.fill" : "keyboard")
                            .foregroundStyle(model.practice.isComplete ? Color.green : Color.secondary)
                    }
                }.frame(height: 105)
                Text(L("This sample does not use your clipboard or take up a workspace slot."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("You can also click the menu bar icon to show the line. Right-click the icon for settings and this guide."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Try later")) { OnboardingWindow.close() }
                Spacer()
                Button(L("Start using Snapline")) { OnboardingWindow.close() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(26).frame(width: 570)
        .environment(\.layoutDirection, Localization.isRTL ? .rightToLeft : .leftToRight)
        .onChange(of: captureText) { _, value in
            Settings.current.autoHangCopiedText = value; applyCaptureSettings()
        }
        .onChange(of: captureImages) { _, value in
            Settings.current.catchClipboard = value; applyCaptureSettings()
        }
    }
    private func applyCaptureSettings() {
        Settings.save()
        NotificationCenter.default.post(name: .snaplineSettingsChanged, object: nil)
    }
}

/// Also supports app-directed keyboard events while practicing. Carbon handles
/// the global path; ordinary key equivalents keep the focused guide accessible.
@MainActor
private final class OnboardingHostWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !(firstResponder is RecordShortcutButton), ShortcutController.shared.registered,
           KeyboardShortcut.from(event) == ShortcutController.shared.shortcut,
           OnboardingWindow.handleShortcut() { return true }
        return super.performKeyEquivalent(with: event)
    }
}
