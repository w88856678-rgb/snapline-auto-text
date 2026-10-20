import AppKit
import SwiftUI

/// A sheet of coloured paper to write on. What you type is drawn onto the
/// note on the line as you go.
@MainActor
enum NoteWindow {
    private static var open: [URL: NSWindow] = [:]
    static var isEditing: Bool { !open.isEmpty }

    static func show(_ url: URL, line: Line) {
        if let w = open[url] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let data = Notes.get(url) else { return }
        let model = NoteModel(url: url, data: data, line: line)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("Edit note")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(rootView: NoteView(model: model))
        window.center()
        open[url] = window
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.flush()
                open[url] = nil
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class NoteModel: ObservableObject {
    let url: URL
    let line: Line
    @Published var text: String { didSet { touched() } }
    @Published var color: String { didSet { touched() } }
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    init(url: URL, data: Settings.NoteData, line: Line) {
        self.url = url; self.line = line
        text = data.text; color = data.color
    }

    private func touched() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { save() }
        }
    }

    func flush() { saveTask?.cancel(); save() }

    private func save() {
        guard dirty else { return }
        dirty = false
        Notes.update(url, text: text, color: color)
        line.reloadThumbnail(for: url)
    }
}

struct NoteView: View {
    @ObservedObject var model: NoteModel

    var body: some View {
        let paper = Color(nsColor: Notes.paper(model.color))
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $model.text)
                .font(.system(size: 20))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .foregroundStyle(Color(red: 0.23, green: 0.19, blue: 0.12))
            HStack(spacing: 10) {
                ForEach(Notes.colors, id: \.self) { key in
                    Circle()
                        .fill(Color(nsColor: Notes.paper(key)))
                        .overlay(Circle().stroke(model.color == key ? Color(red: 0.23, green: 0.19, blue: 0.12) : Color.black.opacity(0.3), lineWidth: model.color == key ? 2.5 : 1))
                        .frame(width: 22, height: 22)
                        .onTapGesture { model.color = key }
                        .help(L(Notes.name(key)))
                }
                Spacer()
                Button(L("Done")) { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(EdgeInsets(top: 30, leading: 22, bottom: 14, trailing: 22))
        .frame(minWidth: 420, minHeight: 340)
        .background(LinearGradient(colors: [paper.lighter(0.1), paper.darker(0.06)], startPoint: .top, endPoint: .bottom))
        .environment(\.layoutDirection, Localization.isRTL ? .rightToLeft : .leftToRight)
    }
}
