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
    private let recentFileImages = RecentImageCaptures()
    private var signalSources: [DispatchSourceSignal] = []
    private var revealState = QuietRevealState()
    private var statusMenu: NSMenu!
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the line can be shown. The panel is ordered in only while revealed.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
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

        setUpStatusItem()
        ShortcutController.shared.onAction = { [weak self] in
            if !OnboardingWindow.handleShortcut() { self?.toggle() }
        }
        ShortcutController.shared.activate()
        updateStatusItem()
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
        center.addObserver(forName: .snaplineShortcutChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        center.addObserver(forName: .snaplineInboxToggle, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.setInbox(note.object as? Bool ?? !Inbox.isEnabled) }
        }

        wanted = line.liveCount > 0
        lastLiveCount = line.liveCount
        refresh()
        if (Settings.current.quietOnboardingVersion ?? 0) < 1 {
            DispatchQueue.main.async { OnboardingWindow.show() }
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
        updateStatusItem()
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
            onCapture: { [weak self] url, _ in self?.hangCapture(url, fromClipboard: true) },
            onText: { [weak self] text in self?.hangCopiedText(text) },
            recentlyHungFromFile: { [weak self] image in
                guard let self, let url = self.recentFileImages.matchingURL(image, source: .file),
                      let item = self.line.liveItems.first(where: { $0.url == url }),
                      ClipboardImage(contentsOf: url)?.fingerprint == image.fingerprint else { return false }
                self.prepareForCapture(on: nil)
                self.line.recapture(item.id)
                self.comeDown(on: self.panel.screen)
                return true
            })
        clipboard.enabled = Settings.current.catchClipboard
        clipboard.textEnabled = Settings.current.autoHangCopiedText
        clipboard.start()
    }

    private func hangCopiedText(_ text: String) {
        prepareForCapture(on: nil)
        guard line.hangCopiedText(text, quietly: !isRevealed) != nil else { return }
        comeDown(on: panel.screen)
    }

    /// Once the pointer reaches a card or navigation control, keep those
    /// cards stable while new copies are collected in the background.
    private func prepareForCapture(on screen: NSScreen?) {
        if isRevealed && (line.isBrowsing || pointerOverContent(NSEvent.mouseLocation)
                          || line.menuOpen || GrabView.isDragging || line.pressedID != nil) {
            line.beginBrowsing()
        } else if !isRevealed {
            line.endBrowsing()
        }
        if !(isRevealed && line.isBrowsing) {
            panel.placeOnScreen(screen)
            updateCapacity()
        }
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

    /// Record new content without revealing the line, including replacements
    /// that leave the live item count unchanged.
    private func comeDown(on screen: NSScreen?) {
        if let id = line.latestCaptureID {
            revealState.capture(id, liveIDs: Set(line.liveItems.map(\.id)))
        }
        updateStatusItem()
        if !isRevealed {
            wanted = line.liveCount > 0 || keepOpen
            refresh()
            return
        }
        if isRevealed && line.isBrowsing {
            wanted = true
            refresh()
            return
        }
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL, fromClipboard: Bool = false) {
        let image = ClipboardImage(contentsOf: url)
        if !fromClipboard, let image,
           let existingURL = recentFileImages.matchingURL(image, source: .clipboard),
           line.liveItems.contains(where: { $0.url == existingURL }),
           ClipboardImage(contentsOf: existingURL)?.fingerprint == image.fingerprint {
            // A saved screenshot may arrive after the clipboard snapshot.
            // Keep the existing card and the newer clipboard browsing target.
            return
        }
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            let center = CGPoint(x: from.midX, y: from.midY)
            return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        prepareForCapture(on: screen)
        guard let id = line.hang(url, quietly: !isRevealed, flying: from != nil && isRevealed) else {
            itemsChanged()
            return
        }
        if let image {
            recentFileImages.record(image, url: url, source: fromClipboard ? .clipboard : .file)
        }
        comeDown(on: panel.screen)
        guard isRevealed, let from else { return }
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
        // Hidden lines watch the top edge only when hover reveal is enabled.
        if wanted && (isRevealed || Settings.current.hoverRevealEnabled) { startMouseTracking() }
        else { stopMouseTracking() }
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

    private func reveal(manually: Bool = false) {
        guard isPresent else { return }
        revealState.open(manually: manually)
        awaySince = nil
        setRevealed(true)
        updateStatusItem()
        startMouseTracking()
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
            revealState.close()
            line.endBrowsing()
            panel.ignoresMouseEvents = true
            if !Settings.current.hoverRevealEnabled { stopMouseTracking() }
        }
    }

    @objc private func toggle() {
        guard !isInteracting else { return }
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
        reveal(manually: true)
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

    private var isInteracting: Bool {
        line.menuOpen || GrabView.isDragging || line.pressedID != nil || NoteWindow.isEditing || MarkupWindow.isEditing
    }

    private func overStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
    }

    /// Clicks that pass through the transparent panel dismiss only the line.
    /// A card, note editor, menu, or an active drag keeps its interaction intact.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRevealed, !self.isInteracting else { return }
                let point = NSEvent.mouseLocation
                guard !self.pointerOverContent(point), !self.overStatusItem(point) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                self.setRevealed(false)
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
            if Settings.current.hoverRevealEnabled, let screen = screenUnderPointer, inRevealArea, !menuBarSuppressed,
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
        if pointerOverContent(mouse) || line.menuOpen || GrabView.isDragging || line.pressedID != nil {
            line.beginBrowsing()
        }

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if revealState.isManual { awaySince = nil; return }

        // With "stay down until used", the line waits while something fresh hangs on it.
        let waiting = Settings.current.stayDownWhileUnused && line.hasUnused
        let busy = waiting || isInteracting
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
        let overSomething = pointerOverContent(mouse)
        if panel.ignoresMouseEvents == overSomething {
            panel.ignoresMouseEvents = !overSomething
        }
    }

    private func pointerOverContent(_ mouse: NSPoint) -> Bool {
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
            || line.extraHitRects.contains { $0.contains(flipped) }
    }

    private func updateCapacity() {
        line.maxItems = 20
        line.pageSize = Layout.pageSize(for: panel.frame.width)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.statusImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu = NSMenu()
        statusMenu.delegate = self
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let button = statusItem.button else { return }
            menuNeedsUpdate(statusMenu)
            line.menuOpen = true
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
            line.menuOpen = false
        } else {
            toggle()
        }
    }

    private func updateStatusItem() {
        guard statusItem != nil else { return }
        let count = revealState.unseenIDs.count
        statusItem.button?.title = count > 0 ? " •" : ""
        statusItem.button?.imagePosition = .imageLeading
        let controller = ShortcutController.shared
        let detail = controller.registered
            ? String(format: L("Press %@ to show or hide the line"), controller.shortcut.label)
            : L("Shortcut unavailable. Right-click to change it.")
        statusItem.button?.toolTip = "Snapline · " + detail + (count > 0 ? " · " + String(format: L("%d new items"), count) : "")
        statusItem.button?.setAccessibilityLabel("Snapline · " + detail)
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
        guard let menu = statusMenu else { return }
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
            // Wait for the menu to close so its interaction guard is released.
            DispatchQueue.main.async { self?.toggle() }
        }
        if ShortcutController.shared.registered {
            toggleItem.keyEquivalent = ShortcutController.shared.shortcut.key.lowercased()
            toggleItem.keyEquivalentModifierMask = ShortcutController.shared.shortcut.flags
        }
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

        let clip = ClosureMenuItem(L("Auto-hang copied images")) { [weak self] in
            Settings.current.catchClipboard.toggle()
            Settings.save()
            self?.clipboard.enabled = Settings.current.catchClipboard
        }
        clip.state = Settings.current.catchClipboard ? .on : .off
        clip.toolTip = L("Copied images, screenshots, and single image files from Finder hang automatically")
        menu.addItem(clip)

        let textClip = ClosureMenuItem(L("Auto-hang copied text")) { [weak self] in
            Settings.current.autoHangCopiedText.toggle()
            Settings.save()
            self?.clipboard.textEnabled = Settings.current.autoHangCopiedText
        }
        textClip.state = Settings.current.autoHangCopiedText ? .on : .off
        textClip.toolTip = L("Copied text becomes a note; double-click to read and edit the full text")
        menu.addItem(textClip)

        let stay = ClosureMenuItem(L("Stay down until each capture is used")) {
            Settings.current.stayDownWhileUnused.toggle()
            Settings.save()
        }
        stay.state = Settings.current.stayDownWhileUnused ? .on : .off
        if Settings.current.hoverRevealEnabled { menu.addItem(stay) }

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

        menu.addItem(ClosureMenuItem(L("View the getting started guide")) { OnboardingWindow.show() })
        menu.addItem(ClosureMenuItem(L("Settings…"), key: ",") {
            SettingsWindow.show()
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Snapline"), key: "q") {
            NSApp.terminate(nil)
        })
    }
}
