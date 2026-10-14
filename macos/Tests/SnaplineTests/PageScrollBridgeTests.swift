import AppKit
import CoreGraphics
import XCTest
@testable import Snapline

final class PageScrollBridgeTests: XCTestCase {
    /// These events remain in memory. They are never posted to the system,
    /// routed to a window, or used to control the user's pointer.
    @MainActor
    private func wheelEvent(lines: Int32, timestamp: CGEventTimestamp) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil,
                                           units: .line, wheelCount: 1,
                                           wheel1: lines, wheel2: 0, wheel3: 0))
        cgEvent.timestamp = timestamp
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertFalse(event.hasPreciseScrollingDeltas)
        XCTAssertEqual(event.scrollingDeltaY, CGFloat(lines))
        return event
    }

    @MainActor
    func testAppKitWheelEventsAdvanceOnceAndHonorControllerCooldown() throws {
        let controller = PageScrollController()
        var steps: [Int] = []
        let start = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)

        let first = try wheelEvent(lines: -3, timestamp: start)
        XCTAssertTrue(controller.handle(first) { steps.append($0) })
        XCTAssertEqual(steps, [1], "One real AppKit wheel event must issue exactly one next-page command")

        let rapid = try wheelEvent(lines: -3, timestamp: start + 100_000_000)
        XCTAssertGreaterThan(rapid.timestamp, first.timestamp)
        XCTAssertTrue(controller.handle(rapid) { steps.append($0) })
        XCTAssertEqual(steps, [1], "A second event 0.1 seconds later must be consumed without another page turn")

        let later = try wheelEvent(lines: -3, timestamp: start + 400_000_000)
        XCTAssertTrue(controller.handle(later) { steps.append($0) })
        XCTAssertEqual(steps, [1, 1], "A new deliberate wheel movement after the cooldown may advance again")

        let reverse = try wheelEvent(lines: 3, timestamp: start + 800_000_000)
        XCTAssertTrue(controller.handle(reverse) { steps.append($0) })
        XCTAssertEqual(steps, [1, 1, -1], "AppKit's opposite wheel direction must reach the previous-page callback")
    }
}
