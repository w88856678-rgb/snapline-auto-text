import AppKit
import XCTest
@testable import Snapline

final class CardDragTests: XCTestCase {
    func testSmallTremorsStayClicksAndDirectPullsDoNotNeedFortyFourPoints() {
        for (dx, dy) in [(0.0, 0.0), (1, 2), (3, 1)] {
            XCTAssertEqual(CardDragIntent.resolve(dx: dx, dy: dy, sliding: false), .waiting)
        }
        for (dx, dy) in [(0.0, -4.0), (0, 4), (3, -3), (-3, -3), (8, -5), (20, -10)] {
            XCTAssertEqual(CardDragIntent.resolve(dx: dx, dy: dy, sliding: false), .export)
        }
    }

    func testClearHorizontalMovementReordersButAPullCanLeaveItQuickly() {
        for dx in [-20.0, -4, 4, 20] {
            XCTAssertEqual(CardDragIntent.resolve(dx: dx, dy: 0, sliding: false), .slide)
        }
        XCTAssertEqual(CardDragIntent.resolve(dx: 15, dy: 2, sliding: true), .slide)
        for dy in [-8.0, 8] {
            XCTAssertEqual(CardDragIntent.resolve(dx: 60, dy: dy, sliding: true), .export)
        }
    }

    @MainActor
    private final class DragProbe: GrabView {
        var sessions: [([NSDraggingItem], NSEvent)] = []
        override func startDragging(items: [NSDraggingItem], event: NSEvent) {
            sessions.append((items, event))
        }
    }

    /// In-memory AppKit events exercise the actual view callbacks. They are
    /// never posted, and the probe does not start a desktop drag session.
    @MainActor
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat,
                       clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: 0, context: nil, eventNumber: 1,
                                        clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
    }

    @MainActor
    private func view() -> DragProbe {
        let view = DragProbe(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.url = URL(fileURLWithPath: "/tmp/SnaplineDragEventTests-image.png")
        view.dragImage = NSImage(size: NSSize(width: 100, height: 50))
        return view
    }

    @MainActor
    func testFirstSmallVerticalMovementStartsOneNativeSessionUsingOriginalGrabEvent() throws {
        let view = view()
        defer { GrabView.isDragging = false }
        var started = 0, copied = 0, slides = 0
        view.onDragStart = { started += 1; XCTAssertTrue(GrabView.isDragging) }
        view.onClick = { copied += 1 }
        view.onSlide = { _ in slides += 1 }
        let down = try event(.leftMouseDown, 100, 50)
        view.mouseDown(with: down)
        view.mouseDragged(with: try event(.leftMouseDragged, 100, 46))
        view.mouseDragged(with: try event(.leftMouseDragged, 100, 20))
        view.mouseUp(with: try event(.leftMouseUp, 100, 20))
        XCTAssertEqual(started, 1)
        XCTAssertEqual(slides, 0)
        XCTAssertEqual(copied, 0)
        XCTAssertEqual(view.sessions.count, 1)
        let session = try XCTUnwrap(view.sessions.first)
        XCTAssertTrue(session.1 === down, "Use AppKit's original grab anchor, not a later pointer position")
        XCTAssertEqual(session.0.count, 1)
        let writer = try XCTUnwrap(session.0.first?.item as? NSPasteboardWriting)
        withTestPasteboard { pasteboard in
            XCTAssertTrue(pasteboard.writeObjects([writer]))
            XCTAssertEqual(pasteboard.string(forType: .fileURL), view.url?.absoluteString)
        }
    }

    @MainActor
    func testDiagonalPullDoesNotRearrangeTheCardBeforeExporting() throws {
        let view = view()
        defer { GrabView.isDragging = false }
        var slides = 0
        view.onSlide = { _ in slides += 1 }
        view.mouseDown(with: try event(.leftMouseDown, 100, 50))
        view.mouseDragged(with: try event(.leftMouseDragged, 103, 47))
        XCTAssertEqual(slides, 0)
        XCTAssertEqual(view.sessions.count, 1)
        view.mouseUp(with: try event(.leftMouseUp, 103, 47))
    }

    @MainActor
    func testHorizontalRearrangementCanBecomeAnExternalDragWithoutFortyFourPointDetour() throws {
        let view = view()
        defer { GrabView.isDragging = false }
        var slides = 0, finished = 0
        view.onSlide = { _ in slides += 1 }
        view.onSlideEnd = { finished += 1 }
        view.mouseDown(with: try event(.leftMouseDown, 100, 50))
        view.mouseDragged(with: try event(.leftMouseDragged, 106, 50))
        XCTAssertEqual(slides, 1)
        XCTAssertTrue(view.sessions.isEmpty)
        view.mouseDragged(with: try event(.leftMouseDragged, 110, 42))
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(view.sessions.count, 1)
        view.mouseUp(with: try event(.leftMouseUp, 110, 42))
        XCTAssertEqual(finished, 1)
    }

    @MainActor
    func testDraggingFromEitherCornerDoesNotDiscardOrOpenAnEditor() throws {
        defer { GrabView.isDragging = false }
        for x in [CGFloat(10), 190] {
            let view = view()
            var discarded = 0, edited = 0, copied = 0
            view.onDiscard = { discarded += 1 }
            view.onPen = { edited += 1 }
            view.onClick = { copied += 1 }
            view.mouseDown(with: try event(.leftMouseDown, x, 90))
            XCTAssertEqual(discarded + edited, 0)
            view.mouseDragged(with: try event(.leftMouseDragged, x, 86))
            view.mouseUp(with: try event(.leftMouseUp, x, 86))
            XCTAssertEqual(view.sessions.count, 1)
            XCTAssertEqual(discarded + edited + copied, 0)
        }
    }

    @MainActor
    func testCornerButtonsCommitOnReleaseAndCanBeCancelledByReleasingOutside() throws {
        let view = view()
        var discarded = 0, edited = 0
        view.onDiscard = { discarded += 1 }
        view.onPen = { edited += 1 }
        view.mouseDown(with: try event(.leftMouseDown, 10, 90))
        XCTAssertEqual(discarded, 0)
        view.mouseUp(with: try event(.leftMouseUp, 10, 90))
        XCTAssertEqual(discarded, 1)
        view.mouseDown(with: try event(.leftMouseDown, 190, 90))
        XCTAssertEqual(edited, 0)
        view.mouseUp(with: try event(.leftMouseUp, 190, 90))
        XCTAssertEqual(edited, 1)
        view.mouseDown(with: try event(.leftMouseDown, 190, 90))
        view.mouseUp(with: try event(.leftMouseUp, 100, 50))
        XCTAssertEqual(edited, 1)
        XCTAssertTrue(view.sessions.isEmpty)
    }

    @MainActor
    func testMicroMovementStillCopiesAndDoubleClickStillEdits() throws {
        let view = view()
        var copied = 0, opened = 0
        view.onClick = { copied += 1 }
        view.onDoubleClick = { opened += 1 }
        view.mouseDown(with: try event(.leftMouseDown, 100, 50))
        view.mouseDragged(with: try event(.leftMouseDragged, 103, 51))
        view.mouseUp(with: try event(.leftMouseUp, 103, 51))
        XCTAssertEqual(copied, 1)
        view.mouseDown(with: try event(.leftMouseDown, 100, 50, clicks: 2))
        view.mouseUp(with: try event(.leftMouseUp, 100, 50, clicks: 2))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(copied, 1)
        XCTAssertTrue(view.sessions.isEmpty)
    }

    @MainActor
    func testStartingADragCancelsTheLongPressEditor() async throws {
        let view = view()
        defer { GrabView.isDragging = false }
        var edited = 0
        view.onLongPress = { edited += 1 }
        view.mouseDown(with: try event(.leftMouseDown, 100, 50))
        view.mouseDragged(with: try event(.leftMouseDragged, 100, 46))
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(edited, 0)
        XCTAssertEqual(view.sessions.count, 1)
        view.mouseUp(with: try event(.leftMouseUp, 100, 46))
    }
}
