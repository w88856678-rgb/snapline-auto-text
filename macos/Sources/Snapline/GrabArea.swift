import AppKit
import SwiftUI

/// Bridges each photo to AppKit's mouse and drag and drop, so it can be
/// dragged into any app as a real file (photos) or plain text (notes).
/// Each destination means one thing:
///
/// - Along the line: the photo moves to where you put it.
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, press and hold opens the editor, the corner cross discards,
/// the corner pen edits.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line
    let width: CGFloat
    var onScroll: (NSEvent) -> Bool = { _ in false }

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let width = width
        view.url = item.url
        view.dragImage = item.thumb
        view.onScroll = onScroll
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = { accepted in
            line.draggingID = nil
            if accepted, let i = line.index(of: id) {
                _ = i
                // Dropped into an app and sent on its way: with the option on, it leaves the line too.
                if Settings.current.takeDownAfterDrag, FileManager.default.fileExists(atPath: line.item(id)?.url.path ?? "") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { line.discard(id) }
                    return
                }
            }
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onPen = { line.markup(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        // Sliding along the line puts the photo where you let go; the others make room when arranging evenly.
        view.onSlide = { screenX in
            guard let panel = view.window else { return }
            let local = panel.convertPoint(fromScreen: NSPoint(x: screenX, y: 0)).x
            let fraction = max(0, min(1, local / max(width, 1)))
            if Settings.current.autoArrange || line.pageCount > 1 {
                let live = line.visibleItems
                var best = 0, bestD = CGFloat.greatestFiniteMagnitude
                for i in 0..<live.count {
                    let d = abs(local - Layout.x(index: i, count: live.count, width: width))
                    if d < bestD { bestD = d; best = i }
                }
                if live.firstIndex(where: { $0.id == id }) != best { line.moveVisible(id, to: best) }
            } else {
                line.setSpot(id, Double(fraction), save: false)
            }
        }
        view.onSlideEnd = { if !Settings.current.autoArrange, line.pageCount == 1, let s = line.item(id)?.spot { line.setSpot(id, s, save: true) } }
        view.menuProvider = {
            let menu = NSMenu()
            let isNote = line.isNote(id)
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            if isNote {
                menu.addItem(ClosureMenuItem(L("Edit note")) { line.editNote(id) })
                let colours = NSMenuItem(title: L("Note colour"), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for key in Notes.colors {
                    let item = ClosureMenuItem(L(Notes.name(key))) { line.recolourNote(id, key) }
                    item.image = Notes.swatch(key)
                    sub.addItem(item)
                }
                colours.submenu = sub
                menu.addItem(colours)
            } else {
                menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
                menu.addItem(ClosureMenuItem(L("Mark up")) { line.markup(id) })
                menu.addItem(ClosureMenuItem(L("Mark up with macOS")) { line.markupWithSystem(id) })
            }
            menu.addItem(ClosureMenuItem(L("Copy text")) { line.copyText(id) })
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let keep = ClosureMenuItem(L("Keep on the line")) { line.togglePin(id) }
            keep.state = (line.item(id)?.pinned ?? false) ? .on : .off
            menu.addItem(keep)
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) })
            }
            return menu
        }
    }
}

extension Notes {
    static func name(_ key: String) -> String {
        switch key {
        case "pink": return "Pink"
        case "blue": return "Blue"
        case "green": return "Green"
        case "orange": return "Orange"
        default: return "Yellow"
        }
    }

    static func swatch(_ key: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            paper(key).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
        return image
    }
}

final class GrabView: NSView, NSDraggingSource {
    nonisolated(unsafe) static var isDragging = false

    var url: URL?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: (Bool) -> Void = { _ in }
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onPen: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var onSlide: (CGFloat) -> Void = { _ in }
    var onSlideEnd: () -> Void = {}
    var onScroll: (NSEvent) -> Bool = { _ in false }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var downScreen: NSPoint?
    private var startedDrag = false
    private var draggingText = false
    private var sliding = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before the editor opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45
    /// How far down or up the pointer goes before a slide along the line becomes a drag out.
    private static let pullAway: CGFloat = 44

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if !onScroll(event) { super.scrollWheel(with: event) }
    }

    static let cornerHitSize: CGFloat = 26

    private func corner(of event: NSEvent) -> Int {
        let p = convert(event.locationInWindow, from: nil)
        let top = isFlipped ? 0 : bounds.height - Self.cornerHitSize
        if NSRect(x: 0, y: top, width: Self.cornerHitSize, height: Self.cornerHitSize).contains(p) { return 1 }
        if NSRect(x: bounds.width - Self.cornerHitSize, y: top, width: Self.cornerHitSize, height: Self.cornerHitSize).contains(p) { return 2 }
        return 0
    }

    override func mouseDown(with event: NSEvent) {
        switch corner(of: event) {
        case 1: downPoint = nil; onDiscard(); return
        case 2: downPoint = nil; onPen(); return
        default: break
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        downScreen = NSEvent.mouseLocation
        startedDrag = false
        sliding = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag, !self.sliding else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let startScreen = downScreen, !startedDrag, let url else { return }
        let p = event.locationInWindow
        let now = NSEvent.mouseLocation
        let dx = now.x - startScreen.x, dy = now.y - startScreen.y
        guard !didLongPress else { return }

        if sliding {
            if abs(dy) > Self.pullAway {
                // Pulled away from the line: it becomes a real drag into another app.
                sliding = false
                onSlideEnd()
                beginDrag(url: url, event: event)
                return
            }
            onSlide(now.x + grabOffset)
            return
        }

        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        endPress()
        if abs(dy) <= Self.pullAway && abs(dx) >= 4 {
            // Sliding along the line moves the photo.
            sliding = true
            if let window {
                let frameInScreen = window.convertToScreen(convert(bounds, to: nil))
                grabOffset = frameInScreen.midX - startScreen.x
            }
            onSlide(now.x + grabOffset)
            return
        }
        if abs(dy) <= Self.pullAway { return }
        beginDrag(url: url, event: event)
    }

    /// The pointer grabbed the card somewhere; keep that offset so the card does not jump.
    private var grabOffset: CGFloat = 0

    private func beginDrag(url: URL, event: NSEvent) {
        startedDrag = true
        endPress()
        draggingText = Notes.isNote(url)
        let item = NSDraggingItem(pasteboardWriter: CardTransfer.dragWriter(for: url))
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if sliding {
            sliding = false
            onSlideEnd()
        } else if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 {
            onClick()
        }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if draggingText { return context == .outsideApplication ? .copy : [] }
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        return context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd(false)
            onTrash()
            return
        }
        let accepted = !operation.isEmpty
        onDragEnd(accepted)
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done(false) }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
