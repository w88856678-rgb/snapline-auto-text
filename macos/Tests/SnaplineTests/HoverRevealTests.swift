import AppKit
import XCTest
@testable import Snapline

final class HoverRevealTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 900)
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 870)

    func testTopEdgeRevealsOnlyInsideTheSelectedScreen() {
        XCTAssertTrue(HoverReveal.contains(CGPoint(x: 500, y: 899), screenFrame: screen,
                                           visibleFrame: visible, menuBarHeight: 30, lineOffset: 0))
        XCTAssertTrue(HoverReveal.contains(CGPoint(x: 500, y: 870), screenFrame: screen,
                                           visibleFrame: visible, menuBarHeight: 30, lineOffset: 0))
        XCTAssertFalse(HoverReveal.contains(CGPoint(x: -1, y: 899), screenFrame: screen,
                                            visibleFrame: visible, menuBarHeight: 30, lineOffset: 0))
        XCTAssertFalse(HoverReveal.contains(CGPoint(x: 1001, y: 899), screenFrame: screen,
                                            visibleFrame: visible, menuBarHeight: 30, lineOffset: 0))
        XCTAssertFalse(HoverReveal.contains(CGPoint(x: 500, y: 901), screenFrame: screen,
                                            visibleFrame: visible, menuBarHeight: 30, lineOffset: 0))
    }

    func testNarrowRopeBandRevealsButOrdinaryUpperDocumentDoesNot() {
        // At the center of a 1000pt screen the rope is 46pt below visible.maxY,
        // so its screen coordinate is 824. Only its narrow hover band reveals it.
        for y in [824.0, 824 - 13.9, 824 + 13.9] {
            XCTAssertTrue(HoverReveal.contains(CGPoint(x: 500, y: y), screenFrame: screen,
                                               visibleFrame: visible, menuBarHeight: 30, lineOffset: 0))
        }
        for y in [824 - 14.1, 824 + 14.1, 750, 700, 600, 500] {
            XCTAssertFalse(HoverReveal.contains(CGPoint(x: 500, y: y), screenFrame: screen,
                                                visibleFrame: visible, menuBarHeight: 30, lineOffset: 0),
                           "Moving within an ordinary document must not reveal the line")
        }
    }

    func testNegativeCoordinateDisplayUsesItsOwnRopeAndTopEdge() {
        let otherScreen = CGRect(x: -1000, y: 100, width: 1000, height: 900)
        let otherVisible = CGRect(x: -1000, y: 130, width: 1000, height: 840)
        // visible.maxY 970 - 40pt line offset - 46pt center sag = 884.
        XCTAssertTrue(HoverReveal.contains(CGPoint(x: -500, y: 884), screenFrame: otherScreen,
                                           visibleFrame: otherVisible, menuBarHeight: 30, lineOffset: 40))
        XCTAssertTrue(HoverReveal.contains(CGPoint(x: -500, y: 999), screenFrame: otherScreen,
                                           visibleFrame: otherVisible, menuBarHeight: 30, lineOffset: 40))
        XCTAssertFalse(HoverReveal.contains(CGPoint(x: -500, y: 700), screenFrame: otherScreen,
                                            visibleFrame: otherVisible, menuBarHeight: 30, lineOffset: 40))
        XCTAssertFalse(HoverReveal.contains(CGPoint(x: 1, y: 999), screenFrame: otherScreen,
                                            visibleFrame: otherVisible, menuBarHeight: 30, lineOffset: 40))
        XCTAssertFalse(HoverReveal.contains(CGPoint(x: -1001, y: 999), screenFrame: otherScreen,
                                            visibleFrame: otherVisible, menuBarHeight: 30, lineOffset: 40))
    }

    func testLineOffsetIsClampedToTheSameRangeAsThePanel() {
        for offset in [-100.0, 0] {
            XCTAssertTrue(HoverReveal.contains(CGPoint(x: 500, y: 824), screenFrame: screen,
                                               visibleFrame: visible, menuBarHeight: 30, lineOffset: offset))
            XCTAssertFalse(HoverReveal.contains(CGPoint(x: 500, y: 624), screenFrame: screen,
                                                visibleFrame: visible, menuBarHeight: 30, lineOffset: offset))
        }
        for offset in [200.0, 500] {
            XCTAssertTrue(HoverReveal.contains(CGPoint(x: 500, y: 624), screenFrame: screen,
                                               visibleFrame: visible, menuBarHeight: 30, lineOffset: offset))
            XCTAssertFalse(HoverReveal.contains(CGPoint(x: 500, y: 824), screenFrame: screen,
                                                visibleFrame: visible, menuBarHeight: 30, lineOffset: offset))
        }
        XCTAssertTrue(HoverReveal.contains(CGPoint(x: 500, y: 899), screenFrame: screen,
                                           visibleFrame: visible, menuBarHeight: 30, lineOffset: 500),
                      "Moving the line down must not disable top-edge reveal")
    }
}
