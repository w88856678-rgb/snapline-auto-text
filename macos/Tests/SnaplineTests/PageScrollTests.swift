import XCTest
@testable import Snapline

final class PageScrollTests: XCTestCase {
    func testPreciseSwipeNeedsThresholdAndTurnsOnlyOnceEvenAfterPause() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 18, deltaY: 0, precise: true, phase: .began, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 19, deltaY: 0, precise: true, phase: .changed, timestamp: 0.1))
        XCTAssertEqual(scroll.ingest(deltaX: 4, deltaY: 0, precise: true, phase: .changed, timestamp: 0.2), 1)
        XCTAssertNil(scroll.ingest(deltaX: 200, deltaY: 0, precise: true, phase: .changed, timestamp: 0.3))
        XCTAssertNil(scroll.ingest(deltaX: 200, deltaY: 0, precise: true, phase: .changed, timestamp: 1.2),
                     "A pause within an explicitly phased gesture must not turn a second page")
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: 0, precise: true, phase: .ended, timestamp: 1.3))
        XCTAssertEqual(scroll.ingest(deltaX: -45, deltaY: 0, precise: true, phase: .began, timestamp: 1.4), -1)
    }

    func testTrackpadMomentumNeverTurnsAPage() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 25, deltaY: 0, precise: true, phase: .began, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 100, deltaY: 0, precise: true, momentum: true, timestamp: 0.1),
                     "An under-threshold swipe must not become a page turn through momentum")
        XCTAssertNil(scroll.ingest(deltaX: -100, deltaY: 0, precise: true, momentum: true, timestamp: 1))
        XCTAssertEqual(scroll.ingest(deltaX: 45, deltaY: 0, precise: true, phase: .began, timestamp: 1.1), 1)
        XCTAssertNil(scroll.ingest(deltaX: 100, deltaY: 0, precise: true, momentum: true, timestamp: 1.2))
    }

    func testVerticalAndDiagonalTrackpadScrollingDoNotAccidentallyPage() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 2, deltaY: 30, precise: true, phase: .began, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 50, deltaY: 5, precise: true, phase: .changed, timestamp: 0.1),
                     "A gesture that began vertically must not change into accidental paging")
        XCTAssertFalse(scroll.isHorizontalGesture)
        XCTAssertNil(scroll.ingest(deltaX: 50, deltaY: 45, precise: true, phase: .began, timestamp: 1))
        XCTAssertFalse(scroll.isHorizontalGesture)
        XCTAssertNil(scroll.ingest(deltaX: 15, deltaY: 1, precise: true, phase: .began, timestamp: 2))
        XCTAssertNil(scroll.ingest(deltaX: 30, deltaY: 70, precise: true, phase: .changed, timestamp: 2.1),
                     "Horizontal jitter at the beginning must not override a predominantly vertical gesture")
    }

    func testReversePreciseMovementMustReachNetThreshold() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 30, deltaY: 0, precise: true, phase: .began, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: -25, deltaY: 0, precise: true, phase: .changed, timestamp: 0.1))
        XCTAssertNil(scroll.ingest(deltaX: -35, deltaY: 0, precise: true, phase: .changed, timestamp: 0.2))
        XCTAssertEqual(scroll.ingest(deltaX: -11, deltaY: 0, precise: true, phase: .changed, timestamp: 0.3), -1)
    }

    func testCancelledSwipeDoesNotContinueUntilANewGestureBegins() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 30, deltaY: 0, precise: true, phase: .began, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 100, deltaY: 0, precise: true, phase: .cancelled, timestamp: 0.1))
        XCTAssertNil(scroll.ingest(deltaX: 100, deltaY: 0, precise: true, phase: .changed, timestamp: 0.2))
        XCTAssertEqual(scroll.ingest(deltaX: 45, deltaY: 0, precise: true, phase: .began, timestamp: 0.3), 1)
    }

    func testMouseWheelAccumulatesSmallTicksAndThrottlesRapidTurns() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 0.05))
        XCTAssertEqual(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 0.1), 1)
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -20, precise: false, timestamp: 0.2))
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 0.3),
                     "Suppressed wheel movement must not queue up a second page")
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 0.4))
        XCTAssertEqual(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 0.5), 1)
    }

    func testMouseWheelReversalAndIdleDoNotReuseOldJitter() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -2, precise: false, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: 2, precise: false, timestamp: 0.1))
        XCTAssertEqual(scroll.ingest(deltaX: 0, deltaY: 1, precise: false, timestamp: 0.2), -1)
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -2, precise: false, timestamp: 1))
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -1, precise: false, timestamp: 1.5))
        XCTAssertEqual(scroll.ingest(deltaX: 0, deltaY: -2, precise: false, timestamp: 1.6), 1)
    }

    func testUnphasedPreciseMouseNeedsAnIdleGapToStartAnotherGesture() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 20, deltaY: 0, precise: true, timestamp: 0))
        XCTAssertEqual(scroll.ingest(deltaX: 20, deltaY: 0, precise: true, timestamp: 0.1), 1)
        XCTAssertNil(scroll.ingest(deltaX: 80, deltaY: 0, precise: true, timestamp: 0.2))
        XCTAssertEqual(scroll.ingest(deltaX: -45, deltaY: 0, precise: true, timestamp: 0.6), -1)
    }

    func testSwitchingDevicesAndExplicitResetClearGestureState() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: 35, deltaY: 0, precise: true, phase: .began, timestamp: 0))
        XCTAssertEqual(scroll.ingest(deltaX: 0, deltaY: -3, precise: false, timestamp: 0.1), 1)
        XCTAssertNil(scroll.ingest(deltaX: 10, deltaY: 0, precise: true, phase: .began, timestamp: 0.2))
        scroll.reset()
        XCTAssertFalse(scroll.isHorizontalGesture)
        XCTAssertNil(scroll.ingest(deltaX: 35, deltaY: 0, precise: true, phase: .changed, timestamp: 0.3))
        XCTAssertEqual(scroll.ingest(deltaX: 5, deltaY: 0, precise: true, phase: .changed, timestamp: 0.4), 1)
    }

    func testNonFiniteInputDoesNotPoisonSubsequentEvents() {
        var scroll = PageScrollAccumulator()
        XCTAssertNil(scroll.ingest(deltaX: .nan, deltaY: 0, precise: true, phase: .began, timestamp: 0))
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: .infinity, precise: false, timestamp: 0.1))
        XCTAssertNil(scroll.ingest(deltaX: 0, deltaY: -3, precise: false, timestamp: .nan))
        XCTAssertEqual(scroll.ingest(deltaX: 0, deltaY: -3, precise: false, timestamp: 0.2), 1)
    }
}
