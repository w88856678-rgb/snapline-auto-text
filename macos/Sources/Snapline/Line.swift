import AppKit
import Combine
import os

let log = Logger(subsystem: "app.snapline.Snapline", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Copied, dragged out, opened or edited at least once. Restored photos count as used.
    var used = false
    /// Kept on purpose: never pushed off by newer captures.
    var pinned = false
    /// Where it hangs along the line, as a fraction of the width, when photos are not arranged automatically.
    var spot: Double?
    let hungAt = Date()
    /// The picture's size in pixels, read once for the tooltip.
    let pixels: CGSize?

    init(url: URL, thumb: NSImage) {
        self.url = url
        self.thumb = thumb
        pixels = pixelSize(url)
    }

    var isNote: Bool { Notes.isNote(url) }
    /// A stable number for this photo, so a mixed peg keeps its colour.
    var seed: Int { url.path.unicodeScalars.reduce(17) { ($0 &* 31) &+ Int($1.value) } }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb && a.pinned == b.pinned && a.spot == b.spot
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var pageIndex = 0
    @Published var pageSize = 7 {
        didSet {
            if pageSize < 1 { pageSize = 1 }
            if pageSize != oldValue { resizePages() }
            clampPage()
        }
    }
    /// Captures must not move the cards a person is looking at or reaching for.
    @Published private(set) var isBrowsing = false
    /// New cards waiting behind the "Latest" button. Counts cards, not copy events.
    @Published private(set) var pendingCount = 0
    /// Freeze page membership, rather than numeric offsets: eviction elsewhere
    /// on the line must not slide a different card underneath the pointer.
    @Published private var browsingPages: [[UUID]]? = nil
    private var pendingIDs: Set<UUID> = []
    private var overflowID: UUID?
    @Published private(set) var latestCaptureID: UUID? = nil
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    /// What the badge under the card says: "Copied", or "Text copied".
    @Published var copiedLabel = L("Copied")
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false
    /// Bumped when the look changes in Settings, so views redraw.
    @Published var look = 0
    /// A context menu is open: clicks belong to it, not to the window underneath.
    var menuOpen = false

    /// Card frames in window coordinates, reported by the views.
    var hitRects: [UUID: CGRect] = [:]
    /// The paper tag and the rope, when they take the mouse.
    var extraHitRects: [CGRect] = []

    var maxItems = 20
    /// The width of the line on screen, from the view, for placing new photos.
    var layoutWidth: CGFloat = 0
    let persist: Bool
    /// Restoring one card must not overwrite the saved metadata of the rest.
    private var restoring = false

    var soundOn: Bool {
        get { Settings.current.soundOn }
        set { Settings.current.soundOn = newValue; Settings.save() }
    }

    var liveItems: [Pegged] { items.filter { !$0.falling } }
    var liveCount: Int { liveItems.count }
    var pageCount: Int { max(1, pages.count) }
    var pageStart: Int { pageIndex * pageSize }
    var visibleItems: [Pegged] {
        let current = pages
        guard current.indices.contains(pageIndex) else { return [] }
        return current[pageIndex]
    }
    /// Whether something hangs that has not been copied, dragged out or opened yet.
    var hasUnused: Bool { items.contains { !$0.falling && !$0.used } }

    init(persist: Bool = true) {
        self.persist = persist
        if persist { restore() }
        scheduleGust()
    }

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    func item(_ id: UUID) -> Pegged? { items.first { $0.id == id } }

    private var pages: [[Pegged]] {
        let live = liveItems
        if let browsingPages {
            let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            return browsingPages.map { $0.compactMap { byID[$0] } }
        }
        let recent = Array(live.reversed())
        return stride(from: 0, to: recent.count, by: pageSize).map {
            Array(recent.dropFirst($0).prefix(pageSize))
        }
    }

    private func snapshotPages() {
        let recent = Array(liveItems.reversed())
        browsingPages = stride(from: 0, to: recent.count, by: pageSize).map {
            Array(recent.dropFirst($0).prefix(pageSize)).map(\.id)
        }
    }

    /// Hovering or navigating starts an uninterrupted visit to these cards.
    func beginBrowsing() {
        if browsingPages == nil { snapshotPages() }
        isBrowsing = true
    }

    /// Hiding releases eviction protection, but ordinary show/hide keeps the
    /// same page. The next capture may follow the newest item again.
    func endBrowsing() { isBrowsing = false }

    /// Explicitly leave the saved browsing position and look at fresh captures.
    func showLatest() {
        browsingPages = nil
        pendingIDs.removeAll()
        pendingCount = 0
        pageIndex = 0
        if !liveItems.contains(where: { $0.id == latestCaptureID }) {
            latestCaptureID = liveItems.last?.id
        }
        if let latestCaptureID { showPage(containing: latestCaptureID) }
        if isBrowsing { snapshotPages() }
    }

    func showPage(_ index: Int) {
        beginBrowsing()
        selectPage(index)
    }

    private func selectPage(_ index: Int) {
        let target = max(0, min(index, pageCount - 1))
        if pageIndex != target { pageIndex = target }
    }

    func showPage(containing id: UUID) {
        guard let index = pages.firstIndex(where: { $0.contains { $0.id == id } }) else { return }
        selectPage(index)
    }

    private func clampPage() { selectPage(pageIndex) }

    private func resizePages() {
        guard browsingPages != nil else { return }
        let anchor = visibleItems.first?.id
        // A real screen-size change is an explicit reflow. Keep its first
        // visible card in view and keep unseen captures behind "Latest".
        let knownIDs = Set(browsingPages?.flatMap { $0 } ?? [])
        let known = Array(liveItems.reversed()).filter { knownIDs.contains($0.id) }
        browsingPages = stride(from: 0, to: known.count, by: pageSize).map {
            Array(known.dropFirst($0).prefix(pageSize)).map(\.id)
        }
        if let anchor { showPage(containing: anchor) }
    }

    private func removeFromPages(_ id: UUID) {
        guard let saved = browsingPages else { return }
        let anchor = visibleItems.first(where: { $0.id != id })?.id
        browsingPages = saved.map { $0.filter { $0 != id } }.filter { !$0.isEmpty }
        if let anchor { showPage(containing: anchor) }
        clampPage()
    }

    private func markPending(_ id: UUID) {
        pendingIDs.insert(id)
        pendingCount = pendingIDs.count
    }

    private func followCapture(_ id: UUID) {
        latestCaptureID = id
        if isBrowsing && pages.contains(where: { !$0.isEmpty }) {
            markPending(id)
        } else {
            showLatest()
        }
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        let protected = isBrowsing ? Set(visibleItems.map(\.id)) : []
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        if !Settings.current.autoArrange {
            item.spot = Layout.freeSpot(taken: items.filter { !$0.falling }.compactMap(\.spot), width: layoutWidth)
        }
        items.append(item)
        // Never immediately discard the item just added. If every old card is
        // pinned, keep one temporary extra card; the next copy can replace it.
        while liveCount > maxItems {
            let oldest = items.first {
                !$0.falling && !$0.pinned && $0.id != item.id && !protected.contains($0.id)
            }
            // Even if the previous temporary extra is on screen, never keep
            // accumulating extra cards when all ordinary slots are protected.
            let previousExtra = overflowID.flatMap { previous in
                items.first { $0.id == previous && !$0.falling && !$0.pinned && $0.id != item.id }
            }
            guard let victim = oldest ?? previousExtra else { break }
            drop(victim.id, quietly: true)
        }
        overflowID = liveCount > maxItems ? item.id : nil
        if !restoring { followCapture(item.id) }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = index(of: id), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        removeFromPages(id)
        pendingIDs.remove(id)
        pendingCount = pendingIDs.count
        if overflowID == id { overflowID = nil }
        clampPage()
        hitRects[id] = nil
        Originals.forget(items[i].url)
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            Notes.forget(item.url)
            drop(item.id, quietly: true)
        }
    }

    // MARK: Placing

    /// Moves a photo to another place on the line. `liveIndex` counts only photos that are not falling.
    func move(_ id: UUID, to liveIndex: Int) {
        guard let from = index(of: id) else { return }
        let item = items[from]
        var live = items.filter { !$0.falling && $0.id != id }
        let target = max(0, min(liveIndex, live.count))
        items.remove(at: from)
        if target < live.count, let at = items.firstIndex(where: { $0.id == live[target].id }) {
            items.insert(item, at: at)
        } else {
            items.append(item)
        }
        live = []
        if let saved = browsingPages {
            let order = Dictionary(uniqueKeysWithValues: liveItems.reversed().enumerated().map { ($0.element.id, $0.offset) })
            browsingPages = saved.map { $0.sorted { order[$0, default: .max] < order[$1, default: .max] } }
        }
        save()
    }

    /// Reorder a displayed page without exposing its reversed, possibly frozen
    /// pagination order to the drag handler. Non-visible cards keep their slots.
    func moveVisible(_ id: UUID, to visibleIndex: Int) {
        beginBrowsing()
        var ordered = visibleItems
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let moving = ordered.remove(at: from)
        ordered.insert(moving, at: max(0, min(visibleIndex, ordered.count)))
        let memberIDs = Set(ordered.map(\.id))
        let slots = items.indices.filter { !items[$0].falling && memberIDs.contains(items[$0].id) }
        for (slot, card) in zip(slots, ordered.reversed()) { items[slot] = card }
        if browsingPages?.indices.contains(pageIndex) == true {
            browsingPages?[pageIndex] = ordered.map(\.id)
        }
        save()
    }

    /// Remembers where a photo was put by hand.
    func setSpot(_ id: UUID, _ fraction: Double, save persistNow: Bool) {
        guard let i = index(of: id) else { return }
        items[i].spot = max(0, min(1, fraction))
        if persistNow { save() }
    }

    /// Keeps a photo on the line: newer captures never push it off.
    func togglePin(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].pinned.toggle()
        save()
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].used = true
        let item = items[i]
        let entry: NSPasteboardItem
        if let note = Notes.get(item.url) {
            entry = CardTransfer.textItem(note.text)
        } else {
            entry = NSPasteboardItem()
            entry.setData(Data(), forType: ClipboardContent.ownCopyType)
            if let png = pngData(item.url) { entry.setData(png, forType: .png) }
            entry.setString(item.url.absoluteString, forType: .fileURL)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        copiedLabel = L("Copied")
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    /// Reads the text in the screenshot with Vision and puts it on the clipboard.
    func copyText(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].used = true
        let url = items[i].url
        Task { @MainActor in
            let text: String?
            if let note = Notes.get(url) { text = note.text }
            else { text = await Ocr.read(url) }
            guard let text, !text.isEmpty else { NSSound.beep(); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            let entry = CardTransfer.textItem(text)
            pb.writeObjects([entry])
            self.copiedLabel = L("Text copied")
            self.copiedID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                if self?.copiedID == id { self?.copiedID = nil }
            }
        }
    }

    func open(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].used = true
        if items[i].isNote { editNote(id) } else { NSWorkspace.shared.open(items[i].url) }
    }

    /// Press and hold: the photo opens enlarged with a pen. A note opens its little window.
    func markup(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].used = true
        if items[i].isNote { NoteWindow.show(items[i].url, line: self) }
        else { MarkupWindow.show(items[i].url, line: self) }
    }

    /// The system Markup extension, the one macOS shows for a fresh screenshot.
    func markupWithSystem(_ id: UUID) {
        guard let item = item(id) else { return }
        Markup.shared.edit(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line.
    func trash(_ id: UUID) {
        guard let item = item(id) else { return }
        do {
            if FileManager.default.fileExists(atPath: item.url.path) {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            Notes.forget(item.url)
            if soundOn { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Snapline's own folder. Those are discarded to the Trash.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = item(id) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = item(id) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            Notes.forget(item.url)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Sticky notes

    /// Clipboard notes never open an editor or take keyboard focus. Reuse a
    /// matching live note; once it is taken down the same text may hang again.
    @discardableResult
    func hangCopiedText(_ text: String, in folder: URL = Inbox.folder) -> UUID? {
        if let existing = items.first(where: { !$0.falling && Notes.get($0.url)?.text == text }) {
            followCapture(existing.id)
            save()
            return existing.id
        }
        return hang(Notes.create(color: "yellow", text: text, in: folder))
    }

    /// A new sticky note hangs on the line, ready to be written on.
    @discardableResult
    func newNote(color: String = "yellow") -> UUID? {
        let url = Notes.create(color: color)
        guard let id = hang(url) else { return nil }
        NoteWindow.show(url, line: self)
        return id
    }

    func isNote(_ id: UUID) -> Bool { item(id)?.isNote ?? false }

    func editNote(_ id: UUID) {
        guard let i = index(of: id), items[i].isNote else { return }
        items[i].used = true
        NoteWindow.show(items[i].url, line: self)
    }

    func recolourNote(_ id: UUID, _ color: String) {
        guard let item = item(id), let data = Notes.get(item.url) else { return }
        Notes.update(item.url, text: data.text, color: color)
        reloadThumbnail(for: item.url)
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        guard persist, !restoring else { return }
        let live = items.filter { !$0.falling }
        let recent = live.first(where: { $0.id == latestCaptureID }) ?? live.last
        latestCaptureID = recent?.id
        Settings.current.recentCopyPath = recent?.url.path
        Settings.current.pegged = live.map(\.url.path)
        Settings.current.pinnedPaths = live.filter(\.pinned).map(\.url.path)
        var spots: [String: Double] = [:]
        for item in live { if let s = item.spot { spots[item.url.path] = s } }
        Settings.current.spots = spots
        Settings.save()
    }

    private func restore() {
        // Everything that hung last time comes back; the line's real capacity applies from the next capture on.
        let saved = Settings.current
        let capacity = maxItems
        restoring = true
        maxItems = .max
        defer {
            maxItems = capacity
            restoring = false
            overflowID = liveCount > maxItems ? liveItems.last(where: { !$0.pinned })?.id : nil
            latestCaptureID = liveItems.first(where: { $0.url.path == saved.recentCopyPath })?.id ?? liveItems.last?.id
            showLatest()
            save()
        }
        for path in saved.pegged where FileManager.default.fileExists(atPath: path) {
            if let id = hang(URL(fileURLWithPath: path), quietly: true), let i = index(of: id) {
                items[i].used = true
                items[i].pinned = saved.pinnedPaths.contains(path)
                items[i].spot = saved.spots[path] ?? items[i].spot
            }
        }
    }

    // MARK: Helpers

    func play(_ name: String, volume: Float) {
        guard soundOn, persist, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// The size of the picture in pixels, without decoding it.
func pixelSize(_ url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
    return CGSize(width: w, height: h)
}
