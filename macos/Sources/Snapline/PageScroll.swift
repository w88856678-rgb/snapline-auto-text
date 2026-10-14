import AppKit
import SwiftUI

/// Event-independent paging rules. Trackpad momentum never turns a second
/// page, and a wheel needs a deliberate amount of scrolling between turns.
struct PageScrollAccumulator {
    enum Phase: Equatable {
        case none, mayBegin, began, changed, ended, cancelled
    }

    private enum Device: Equatable { case precise, wheel }
    private enum Axis: Equatable { case undecided, horizontal, vertical }

    private static let swipeThreshold = 40.0
    private static let axisThreshold = 12.0
    private static let axisDominance = 1.35
    private static let wheelThreshold = 3.0
    private static let wheelCooldown = 0.35
    private static let idleReset = 0.28

    private var device: Device?
    private var axis = Axis.undecided
    private var horizontalTotal = 0.0
    private var verticalTotal = 0.0
    private var wheelTotal = 0.0
    private var turnedInGesture = false
    private var lastEventTime: TimeInterval?
    private var lastWheelTurn: TimeInterval?

    var isHorizontalGesture: Bool { device == .precise && axis == .horizontal }

    mutating func reset() { self = Self() }

    /// Returns -1 for the previous page or +1 for the next page. Deltas keep
    /// AppKit's scrolling direction, including the user's natural-scroll setting.
    mutating func ingest(deltaX: Double, deltaY: Double, precise: Bool,
                         phase: Phase = .none, momentum: Bool = false,
                         timestamp: TimeInterval) -> Int? {
        guard deltaX.isFinite, deltaY.isFinite, timestamp.isFinite else { return nil }
        let elapsed = lastEventTime.map { timestamp - $0 }
        if let elapsed, elapsed < 0 { reset() }
        defer { lastEventTime = timestamp }

        // Momentum belongs to the same physical gesture, including when the
        // pointer has moved to another card after the page changed.
        guard !momentum else { return nil }

        if precise {
            if device != .precise || phase == .began || phase == .mayBegin ||
                (phase == .none && (elapsed.map { $0 > Self.idleReset } ?? true)) {
                device = .precise
                axis = .undecided
                horizontalTotal = 0
                verticalTotal = 0
                turnedInGesture = false
            }
            if phase == .cancelled {
                horizontalTotal = 0
                verticalTotal = 0
                turnedInGesture = true
                return nil
            }
            guard !turnedInGesture else { return nil }
            horizontalTotal += deltaX
            verticalTotal += deltaY
            if axis == .undecided {
                let x = abs(horizontalTotal), y = abs(verticalTotal)
                if x >= Self.axisThreshold, x > y * Self.axisDominance { axis = .horizontal }
                else if y >= Self.axisThreshold, y > x * Self.axisDominance { axis = .vertical }
            }
            guard axis == .horizontal, abs(horizontalTotal) >= Self.swipeThreshold,
                  abs(horizontalTotal) > abs(verticalTotal) * Self.axisDominance else { return nil }
            turnedInGesture = true
            return horizontalTotal > 0 ? 1 : -1
        }

        if device != .wheel || (elapsed.map { $0 > Self.idleReset } ?? true) { wheelTotal = 0 }
        device = .wheel
        // A vertical wheel scrolled down advances. Horizontal wheels follow
        // the same content movement as a trackpad swipe.
        let delta = abs(deltaY) >= abs(deltaX) ? -deltaY : deltaX
        if wheelTotal * delta < 0 { wheelTotal = 0 }
        wheelTotal += delta
        guard abs(wheelTotal) >= Self.wheelThreshold else { return nil }
        guard lastWheelTurn.map({ timestamp - $0 >= Self.wheelCooldown }) ?? true else {
            // Do not queue up an extra page while the first turn settles.
            wheelTotal = 0
            return nil
        }
        wheelTotal = 0
        lastWheelTurn = timestamp
        return delta > 0 ? 1 : -1
    }
}

/// One controller is shared by all cards and the page controls, so replacing
/// the visible cards does not turn one swipe into several independent swipes.
@MainActor
final class PageScrollController: ObservableObject {
    private var accumulator = PageScrollAccumulator()

    func reset() { accumulator.reset() }

    /// Call only for an interactive region of the revealed line. A vertical
    /// trackpad gesture is left alone; it is not a paging command.
    @discardableResult
    func handle(_ event: NSEvent, onStep: (Int) -> Void) -> Bool {
        guard event.type == .scrollWheel else { return false }
        let wasHorizontal = accumulator.isHorizontalGesture
        let phase: PageScrollAccumulator.Phase
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.changed) { phase = .changed }
        else { phase = .none }
        if let step = accumulator.ingest(deltaX: Double(event.scrollingDeltaX),
                                         deltaY: Double(event.scrollingDeltaY),
                                         precise: event.hasPreciseScrollingDeltas,
                                         phase: phase,
                                         momentum: event.momentumPhase != [],
                                         timestamp: event.timestamp) { onStep(step) }
        return !event.hasPreciseScrollingDeltas || accumulator.isHorizontalGesture ||
            (wasHorizontal && phase != .began && phase != .mayBegin) ||
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    }
}

/// Adds wheel paging to SwiftUI controls without covering their buttons.
/// It receives events only in its own visible bounds and its own window.
struct PageScrollRegion: NSViewRepresentable {
    let controller: PageScrollController
    var isEnabled = true
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> PageScrollRegionView {
        let view = PageScrollRegionView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PageScrollRegionView, context: Context) { configure(view) }

    private func configure(_ view: PageScrollRegionView) {
        view.isEnabled = isEnabled
        view.onScroll = { event in controller.handle(event, onStep: onStep) }
    }
}

final class PageScrollRegionView: NSView {
    var isEnabled = true
    var onScroll: (NSEvent) -> Bool = { _ in false }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isEnabled, !self.isHiddenOrHasHiddenAncestor,
                  let window = self.window, event.window === window,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            return self.onScroll(event) ? nil : event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
