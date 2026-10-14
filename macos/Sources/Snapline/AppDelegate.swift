import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Copied text and captures that only reach the clipboard.
    private var clipboard: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the line can be shown. The panel is ordered in only while revealed.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. Full screen apps
    /// block it unless the user allows the line over them.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        applyPanelBehavior()
        panel.placeOnScreen()
        updateCapacity()

        // A snapshot left by a run that never quit cleanly goes back first.
        Inbox.recoverIfNeeded()
        Originals.sweep(hanging: line.items.map(\.url))
        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        startClipboardWatcher()

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }
        // The paper tag on the line, or a right-click on the rope: the menu.
        center.addObserver(forName: .snaplineMenuRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popMenu() }
        }
        center.addObserver(forName: .snaplineSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        center.addObserver(forName: .snaplineInboxToggle, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.setInbox(note.object as? Bool ?? !Inbox.isEnabled) }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !Settings.current.welcomed {
            Settings.current.welcomed = true
            Settings.save()
            keepOpen = true
            wanted = true
            refresh()
            reveal(peekFor: 6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        } else if line.liveCount > 0 {
            // Photos restored from last time: the line is there, tucked away.
            wanted = true
            lastLiveCount = line.liveCount
            refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Settings

    private func settingsChanged() {
        applyAppearance()
        clipboard.enabled = Settings.current.catchClipboard
        clipboard.textEnabled = Settings.current.autoHangCopiedText
        applyPanelBehavior()
        panel.placeOnScreen(panel.screen)
        line.look += 1
        // Rebuild the status item title, in case the language changed.
        statusItem.button?.toolTip = "Snapline"
        refresh()
    }

    private func applyPanelBehavior() {
        if Settings.current.showOverFullScreen {
            panel.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            panel.collectionBehavior.remove(.fullScreenAuxiliary)
        }
    }

    private func isBlocked(on screen: NSScreen) -> Bool {
        !Settings.current.showOverFullScreen && FullScreen.isActive(on: screen)
    }

    private func applyAppearance() {
        switch Settings.current.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    nonisolated static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setLaunchesAtLogin(_ on: Bool) {
        guard on != launchesAtLogin else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Snapline to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "SnaplineDiagnosticDataDirectory") is String {
            watcher = ScreenshotWatcher(
                folder: Inbox.folder,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            watcher.start()
            return
        }
        #endif
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    private func startClipboardWatcher() {
        var pasteboard = NSPasteboard.general
        #if DEBUG
        if let name = Bundle.main.object(forInfoDictionaryKey: "SnaplineDiagnosticPasteboard") as? String {
            pasteboard = NSPasteboard(name: .init(name))
        }
        #endif
        clipboard = ClipboardWatcher(
            pasteboard: pasteboard,
            onCapture: { [weak self] url, _ in self?.hangCapture(url) },
            onText: { [weak self] text in self?.hangCopiedText(text) },
            recentlyHungFromFile: { [weak self] size in
                guard let self else { return false }
                return self.line.items.contains { item in
                    !item.falling && Date().timeIntervalSince(item.hungAt) < 5 && pixelSize(item.url) == size
                }
            })
        clipboard.enabled = Settings.current.catchClipboard
        clipboard.textEnabled = Settings.current.autoHangCopiedText
        clipboard.start()
    }

    private func hangCopiedText(_ text: String) {
        // Place it on the screen being used, including when the line is full
        // and its item count does not grow. Do not activate the app.
        panel.placeOnScreen()
        updateCapacity()
        guard line.hangCopiedText(text) != nil else { return }
        wanted = true
        refresh()
        reveal(peekFor: 2.5)
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Snapline handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Snapline quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Snapline") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            comeDown(on: panel.screen)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    /// A new capture brings the line down even when it replaces an old card
    /// and the live item count stays unchanged.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        reveal(peekFor: 2.5)
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            let center = CGPoint(x: from.midX, y: from.midY)
            return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        comeDown(on: screen)
        guard let id = line.hang(url, flying: from != nil) else {
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let item = line.item(id) else { return nil }
        let width = panel.frame.width
        guard let x = Layout.positions(for: line, width: width)[id] else { return nil }
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: item.thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the line can be shown on the current screen.
    private func refresh() {
        let blocked = panel.screen.map(isBlocked(on:))
            ?? LinePanel.screenUnderPointer().map(isBlocked(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            // An invisible strip still appears to screen automation as the
            // topmost window. Remove it after the slide-up animation completes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            showLine()
        }
    }

    private func showLine() {
        keepOpen = true
        wanted = true
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        reveal(peekFor: 2.5)
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.line.menuOpen else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inRevealArea = screenUnderPointer.map {
            HoverReveal.contains(mouse, screenFrame: $0.frame, visibleFrame: $0.visibleFrame,
                                 menuBarHeight: Self.menuBarBand(of: $0).height,
                                 lineOffset: Settings.current.lineOffset)
        } ?? false
        if !inRevealArea { menuBarSuppressed = false }

        guard isRevealed else {
            // Hover near the rope or the top edge to bring it within reach.
            if let screen = screenUnderPointer, inRevealArea, !menuBarSuppressed,
               !isBlocked(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        // With "stay down until used", the line waits while something fresh hangs on it.
        let waiting = Settings.current.stayDownWhileUnused && line.hasUnused
        let busy = pinned || waiting || line.menuOpen || GrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo, the paper tag or the hint.
    /// Everywhere else, clicks go to whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging, !line.menuOpen else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overSomething = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
            || line.extraHitRects.contains { $0.contains(flipped) }
        if panel.ignoresMouseEvents == overSomething {
            panel.ignoresMouseEvents = !overSomething
        }
    }

    private func updateCapacity() {
        line.maxItems = 20
        line.pageSize = Layout.pageSize(for: panel.frame.width)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Self.statusImage()
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Snapline"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The capture-frame mark as a template image, so it follows the menu bar's tone.
    private static func statusImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBar", withExtension: "png"), let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        let fallback = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapline")!
        fallback.isTemplate = true
        return fallback
    }

    /// The same menu as the status item, popped up at the pointer when the
    /// paper tag on the line is clicked.
    private func popMenu() {
        guard let menu = statusItem.menu else { return }
        menuNeedsUpdate(menu)
        line.menuOpen = true
        panel.ignoresMouseEvents = false
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        line.menuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(ClosureMenuItem(L("New capture"), key: "n") {
            Capture.snip()
        })

        let notes = NSMenu()
        for key in Notes.colors {
            let item = ClosureMenuItem(L(Notes.name(key))) { [weak self] in
                guard let self else { return }
                self.showLine()
                self.line.newNote(color: key)
            }
            item.image = Notes.swatch(key)
            notes.addItem(item)
        }
        let noteItem = NSMenuItem(title: L("New note"), action: nil, keyEquivalent: "")
        noteItem.submenu = notes
        menu.addItem(noteItem)

        menu.addItem(.separator())

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = hotKey?.usesFallback == true ? [.control, .option, .shift] : [.control, .option]
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clip = ClosureMenuItem(L("Catch clipboard captures")) { [weak self] in
            Settings.current.catchClipboard.toggle()
            Settings.save()
            self?.clipboard.enabled = Settings.current.catchClipboard
        }
        clip.state = Settings.current.catchClipboard ? .on : .off
        clip.toolTip = L("Cmd+Ctrl+Shift+4 copies instead of saving; those hang too")
        menu.addItem(clip)

        let textClip = ClosureMenuItem("复制文字自动挂上 / Auto-hang copied text") { [weak self] in
            Settings.current.autoHangCopiedText.toggle()
            Settings.save()
            self?.clipboard.textEnabled = Settings.current.autoHangCopiedText
        }
        textClip.state = Settings.current.autoHangCopiedText ? .on : .off
        textClip.toolTip = "复制文字后自动生成便签；双击便签可查看和编辑全文"
        menu.addItem(textClip)

        let stay = ClosureMenuItem(L("Stay down until each capture is used")) {
            Settings.current.stayDownWhileUnused.toggle()
            Settings.save()
        }
        stay.state = Settings.current.stayDownWhileUnused ? .on : .off
        menu.addItem(stay)

        let takeDown = ClosureMenuItem(L("Take down after dragging into an app")) {
            Settings.current.takeDownAfterDrag.toggle()
            Settings.save()
        }
        takeDown.state = Settings.current.takeDownAfterDrag ? .on : .off
        menu.addItem(takeDown)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        menu.addItem(ClosureMenuItem(L("Settings…"), key: ",") {
            SettingsWindow.show()
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Snapline"), key: "q") {
            NSApp.terminate(nil)
        })
    }
}
