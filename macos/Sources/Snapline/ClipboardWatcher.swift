import AppKit

/// Snapshot copied images before the clipboard changes again. A short delay
/// lets the screenshot file watcher win when the same image is also saved.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private let captureFolder: URL
    private let captureDelay: TimeInterval
    private var lastCount: Int
    private var generation = 0
    private var imageGeneration = 0
    private var textGeneration = 0
    private var pendingDeliveries = 0
    private let onCapture: (URL, CGSize) -> Void
    private let onText: (String) -> Void
    private let recentlyHungFromFile: (ClipboardImage) -> Bool
    var enabled = true {
        didSet {
            if enabled != oldValue {
                imageGeneration += 1
                lastCount = pasteboard.changeCount
            }
        }
    }
    var textEnabled = false {
        didSet {
            if textEnabled != oldValue {
                textGeneration += 1
                lastCount = pasteboard.changeCount
            }
        }
    }

    init(pasteboard: NSPasteboard = .general, captureFolder: URL = Inbox.folder,
         captureDelay: TimeInterval = 1.2, onCapture: @escaping (URL, CGSize) -> Void,
         onText: @escaping (String) -> Void, recentlyHungFromFile: @escaping (ClipboardImage) -> Bool) {
        self.pasteboard = pasteboard
        self.captureFolder = captureFolder
        self.captureDelay = captureDelay
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
        pendingDeliveries = 0
        lastCount = pasteboard.changeCount
    }

    func poll() {
        let pb = pasteboard
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard enabled || textEnabled, !ClipboardContent.shouldIgnoreImages(pb) else { return }
        if let image = ClipboardImage.read(from: pb) {
            // A copied image may also carry a web URL, HTML, or a file name.
            // Those are metadata for this copy, not a separate text note.
            guard enabled else { return }
            let scheduledImageGeneration = imageGeneration
            enqueue { watcher in
                guard watcher.enabled, watcher.imageGeneration == scheduledImageGeneration else { return }
                watcher.catchImage(image)
            }
            return
        }
        // Invalid image data is still an image-copy action. Do not turn its
        // accompanying URL or caption into an unrelated text note.
        guard !ClipboardImage.hasImageRepresentation(pb) else { return }
        if textEnabled, let text = ClipboardContent.text(from: pb) {
            if pendingDeliveries > 0 {
                // Keep mixed image/text copies in their original order even
                // while an earlier image is waiting for the file watcher.
                let scheduledTextGeneration = textGeneration
                enqueue { watcher in
                    if watcher.textEnabled, watcher.textGeneration == scheduledTextGeneration { watcher.onText(text) }
                }
            } else {
                onText(text)
            }
        }
    }

    private func enqueue(_ delivery: @escaping (ClipboardWatcher) -> Void) {
        let scheduledGeneration = generation
        pendingDeliveries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.pendingDeliveries -= 1
            delivery(self)
        }
    }

    private func catchImage(_ image: ClipboardImage) {
        if recentlyHungFromFile(image) { return }
        let url = Inbox.newCapturePath(in: captureFolder)
        do {
            try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
            try image.png.write(to: url, options: .atomic)
            log.notice("Caught a clipboard capture: \(url.lastPathComponent, privacy: .public)")
            onCapture(url, image.size)
        } catch {
            log.error("Clipboard capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Inbox {
    /// A fresh file name for a capture, like the system's.
    static func newCapturePath(in folder: URL = Inbox.folder) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = folder.appendingPathComponent("Copied Image \(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Copied Image \(stamp) (\(n)).png")
            n += 1
        }
        return url
    }
}
