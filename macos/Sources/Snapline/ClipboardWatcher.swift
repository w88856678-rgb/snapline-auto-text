import AppKit

/// Copied text becomes an editable note. Pure clipboard screenshots still
/// follow the original capture path, with a short delay to avoid duplicates.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private var lastCount: Int
    private var generation = 0
    private let onCapture: (URL, CGSize) -> Void
    private let onText: (String) -> Void
    private let recentlyHungFromFile: (CGSize) -> Bool
    var enabled = true {
        didSet { if enabled != oldValue { resetBaseline() } }
    }
    var textEnabled = false {
        didSet { if textEnabled != oldValue { resetBaseline() } }
    }

    init(pasteboard: NSPasteboard = .general, onCapture: @escaping (URL, CGSize) -> Void,
         onText: @escaping (String) -> Void, recentlyHungFromFile: @escaping (CGSize) -> Bool) {
        self.pasteboard = pasteboard
        self.lastCount = pasteboard.changeCount
        self.onCapture = onCapture
        self.onText = onText
        self.recentlyHungFromFile = recentlyHungFromFile
    }

    func start() {
        guard timer == nil else { return }
        resetBaseline()
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.08
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        resetBaseline()
    }

    private func resetBaseline() {
        generation += 1
        lastCount = pasteboard.changeCount
    }

    func poll() {
        let pb = pasteboard
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard enabled || textEnabled, !ClipboardContent.shouldIgnore(pb) else { return }
        if textEnabled, let text = ClipboardContent.text(from: pb) {
            onText(text)
        }
        guard enabled else { return }
        let scheduledGeneration = generation
        // Let the file watcher hang a saved capture first; only catch what never reached a file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.enabled, self.generation == scheduledGeneration,
                  pb.changeCount == count, !ClipboardContent.shouldIgnore(pb) else { return }
            self.tryCatch(pb)
        }
    }

    private static let notPureImage: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .html, .fileURL, .URL, NSPasteboard.PasteboardType("public.file-url"),
    ]

    private func tryCatch(_ pb: NSPasteboard) {
        guard let types = pb.types, types.contains(where: { $0 == .png || $0 == .tiff }) else { return }
        if types.contains(where: Self.notPureImage.contains) { return }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let image = NSBitmapImageRep(data: data),
              image.pixelsWide >= 8, image.pixelsHigh >= 8 else { return }
        let size = CGSize(width: image.pixelsWide, height: image.pixelsHigh)
        if recentlyHungFromFile(size) { return }
        guard let png = image.representation(using: .png, properties: [:]) else { return }
        let url = Inbox.newCapturePath()
        do {
            try FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            log.notice("Caught a clipboard capture: \(url.lastPathComponent, privacy: .public)")
            onCapture(url, size)
        } catch {
            log.error("Clipboard capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Inbox {
    /// A fresh file name for a capture, like the system's.
    static func newCapturePath() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = folder.appendingPathComponent("Screenshot \(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Screenshot \(stamp) (\(n)).png")
            n += 1
        }
        return url
    }
}
