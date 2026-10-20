import Foundation
import XCTest
@testable import Snapline

final class QuietRevealTests: XCTestCase {
    func testCopiesAndDisabledHoverNeverRevealAndCountUniqueLiveCards() {
        var state = QuietRevealState()
        let first = UUID(), second = UUID()
        state.capture(first, liveIDs: [first])
        state.hover(enabled: false)
        state.capture(first, liveIDs: [first])
        state.capture(second, liveIDs: [first, second])
        XCTAssertFalse(state.isOpen)
        XCTAssertFalse(state.isManual)
        XCTAssertEqual(state.unseenIDs.count, 2)
    }
    func testManualOpeningClearsBadgeAndCopiesDoNotCloseTheSession() {
        var state = QuietRevealState()
        let first = UUID(), second = UUID()
        state.capture(first, liveIDs: [first])
        state.open(manually: true)
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.isManual)
        XCTAssertTrue(state.unseenIDs.isEmpty)
        state.capture(second, liveIDs: [first, second])
        state.hover(enabled: false)
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.isManual)
        XCTAssertTrue(state.unseenIDs.isEmpty)
        state.close()
        state.capture(second, liveIDs: [first, second])
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.unseenIDs, [second])
    }
    func testAnActiveInteractionProtectsTheOpenSession() {
        var state = QuietRevealState()
        state.open(manually: true)
        state.close(interacting: true)
        XCTAssertTrue(state.isOpen)
        state.close(interacting: false)
        XCTAssertFalse(state.isOpen)
        XCTAssertFalse(state.isManual)
    }
    func testOptionalHoverDoesNotReplaceAManuallyOpenedSession() {
        var state = QuietRevealState()
        state.hover(enabled: true)
        XCTAssertTrue(state.isOpen)
        XCTAssertFalse(state.isManual)
        state.open(manually: true)
        state.hover(enabled: true)
        XCTAssertTrue(state.isManual)
        state.close()
        state.hover(enabled: false)
        XCTAssertFalse(state.isOpen)
    }
    func testEvictedCardsDoNotInflateTheNewContentBadge() {
        var state = QuietRevealState()
        let first = UUID(), second = UUID(), third = UUID()
        state.capture(first, liveIDs: [first])
        state.capture(second, liveIDs: [first, second])
        state.capture(third, liveIDs: [second, third])
        XCTAssertEqual(state.unseenIDs, [second, third])
    }
    func testPracticeNeedsAnOpenThenACloseAndDoesNotTouchSettings() {
        let before = Settings.current.pegged
        let notes = Settings.current.notes.count
        var practice = ShortcutPractice()
        XCTAssertFalse(practice.isComplete)
        XCTAssertFalse(practice.isExpanded)
        practice.toggle()
        XCTAssertTrue(practice.hasOpened)
        XCTAssertTrue(practice.isExpanded)
        XCTAssertFalse(practice.isComplete)
        practice.toggle()
        XCTAssertFalse(practice.isExpanded)
        XCTAssertTrue(practice.isComplete)
        practice.toggle()
        XCTAssertTrue(practice.isComplete)
        XCTAssertEqual(Settings.current.pegged, before)
        XCTAssertEqual(Settings.current.notes.count, notes)
    }
}
