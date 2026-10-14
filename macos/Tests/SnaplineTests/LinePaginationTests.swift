import AppKit
import XCTest
@testable import Snapline

final class LinePaginationTests: XCTestCase {
    @MainActor
    private func withTemporaryLine(_ body: (Line, [URL], URL) throws -> Void) throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        defer {
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplinePaginationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                   pixelsWide: 16, pixelsHigh: 12,
                                                   bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let pictures = (0..<40).map { folder.appendingPathComponent("picture-\($0).png") }
        for picture in pictures { try png.write(to: picture) }
        try body(Line(persist: false), pictures, folder)
    }

    @MainActor
    func testTwentyCardsShowNewestFirstWithoutChangingStoredOrder() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            XCTAssertEqual(line.pageSize, 7)
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.pageCount, 3)
            XCTAssertEqual(line.pageIndex, 0, "The most recent captures must be immediately available on the first page")
            XCTAssertEqual(line.liveItems.map(\.url), Array(pictures.prefix(20)), "Display order must not reverse the persisted oldest-to-newest order")
            let recent = Array(pictures.prefix(20).reversed())
            for page in 0..<3 {
                line.showPage(page)
                XCTAssertEqual(line.pageStart, page * 7)
                XCTAssertEqual(line.visibleItems.map(\.url), Array(recent.dropFirst(page * 7).prefix(page == 2 ? 6 : 7)))
            }

            line.endBrowsing()
            let latestID = try XCTUnwrap(line.hang(pictures[20], quietly: true))

            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.pageIndex, 0, "After browsing ends, a capture must follow the newest item again")
            XCTAssertEqual(line.visibleItems.count, 7)
            XCTAssertEqual(line.visibleItems.first?.id, latestID)
            XCTAssertEqual(line.liveItems.map(\.url), Array(pictures[1...20]))
            XCTAssertEqual(line.pendingCount, 0)
        }
    }

    @MainActor
    func testRepeatedCopiedTextShowsItsExistingPageWithoutCreatingAnotherNote() throws {
        try withTemporaryLine { line, pictures, folder in
            for picture in pictures.prefix(8) { line.hang(picture, quietly: true) }
            let text = "重新复制时找回已有便签 🧺\n完整文字"
            let noteID = try XCTUnwrap(line.hangCopiedText(text, in: folder))
            for picture in pictures.dropFirst(8).prefix(11) { line.hang(picture, quietly: true) }
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.pageIndex, 0)
            let noteCount = Settings.current.notes.count

            XCTAssertEqual(line.hangCopiedText(text, in: folder), noteID)

            XCTAssertEqual(line.pageIndex, 1, "Copying an already hanging note must reveal its original page")
            XCTAssertTrue(line.visibleItems.contains { $0.id == noteID })
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(Settings.current.notes.count, noteCount, "Finding an existing note must not generate another file or metadata record")
        }
    }

    @MainActor
    func testDroppingLastPageAndChangingPageSizeClampsNavigation() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(-2)
            XCTAssertEqual(line.pageIndex, 0)
            line.showPage(999)
            XCTAssertEqual(line.pageIndex, 2)
            let lastPageIDs = line.visibleItems.map(\.id)
            for id in lastPageIDs { line.drop(id, quietly: true) }

            XCTAssertEqual(line.liveCount, 14)
            XCTAssertEqual(line.pageCount, 2)
            XCTAssertEqual(line.pageIndex, 1, "Removing the last page must return to the last remaining page")
            XCTAssertEqual(line.visibleItems.count, 7)
            XCTAssertFalse(line.visibleItems.contains { $0.falling })

            line.pageSize = 20
            XCTAssertEqual(line.pageIndex, 0, "A larger page size must clamp a now-invalid page index")
            XCTAssertEqual(line.pageCount, 1)
            XCTAssertEqual(line.visibleItems.count, 14)
            line.pageSize = 0
            XCTAssertEqual(line.pageSize, 1)
            XCTAssertEqual(line.pageCount, 14)
            line.showPage(999)
            XCTAssertEqual(line.pageIndex, 13)
            let anchor = line.visibleItems.first?.id
            line.pageSize = 7
            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertTrue(line.visibleItems.contains { $0.id == anchor }, "A width change must keep the previously visible anchor reachable")
            line.pageSize = -7
            XCTAssertEqual(line.pageSize, 1, "Invalid page sizes must never cause division by zero or negative slicing")
            XCTAssertEqual(line.visibleItems.count, 1)
        }
    }

    @MainActor
    func testMovingWithinDisplayedPageKeepsOtherCardsAndStoredOrderConsistent() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(1)
            let firstVisible = try XCTUnwrap(line.visibleItems.first)

            let before = line.liveItems.map(\.url)
            line.moveVisible(firstVisible.id, to: 3)

            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertEqual(line.pageStart, 7)
            XCTAssertEqual(line.visibleItems.map(\.url), [pictures[11], pictures[10], pictures[9], pictures[12], pictures[8], pictures[7], pictures[6]])
            XCTAssertEqual(line.liveItems.prefix(6).map(\.url), Array(before.prefix(6)), "Reordering a page must not move older non-visible cards")
            XCTAssertEqual(line.liveItems.suffix(7).map(\.url), Array(before.suffix(7)), "Reordering a page must not move newer non-visible cards")
            line.endBrowsing()
            line.showLatest()
            XCTAssertEqual(line.visibleItems.map(\.url), Array(pictures[13...19].reversed()))
        }
    }

    @MainActor
    func testBrowsingProtectsVisibleIDsAndDoesNotJumpWhenFullLineEvictsElsewhere() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(2)
            let visibleIDs = line.visibleItems.map(\.id)
            let visibleURLs = line.visibleItems.map(\.url)
            XCTAssertEqual(visibleURLs, Array(pictures[0...5].reversed()))

            for picture in pictures[20...25] { line.hang(picture, quietly: true) }

            XCTAssertTrue(line.isBrowsing)
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.pageIndex, 2)
            XCTAssertEqual(line.visibleItems.map(\.id), visibleIDs, "No copied card or background eviction may move a card under the pointer")
            XCTAssertEqual(line.pendingCount, 6)
            XCTAssertTrue(visibleURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(line.liveItems.map(\.url), Array(pictures[0...5]) + Array(pictures[12...25]), "Only unprotected old cards should be evicted")

            line.showLatest()

            XCTAssertEqual(line.pageIndex, 0)
            XCTAssertEqual(line.pendingCount, 0)
            XCTAssertEqual(line.visibleItems.map(\.url), Array(pictures[19...25].reversed()))
        }
    }

    @MainActor
    func testOrdinaryHideAndShowRetainsPageAndCaptureAfterHideFollowsLatest() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(1)
            let visibleIDs = line.visibleItems.map(\.id)
            line.endBrowsing()
            line.beginBrowsing()
            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertEqual(line.visibleItems.map(\.id), visibleIDs)

            line.endBrowsing()
            let latestID = try XCTUnwrap(line.hang(pictures[20], quietly: true))

            XCTAssertFalse(line.isBrowsing)
            XCTAssertEqual(line.pageIndex, 0)
            XCTAssertEqual(line.visibleItems.first?.id, latestID)
            XCTAssertEqual(line.pendingCount, 0)
        }
    }

    @MainActor
    func testPendingCapturesDoNotPreventPagingThroughTheSavedPages() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(15) { line.hang(picture, quietly: true) }
            line.showPage(1)
            let originalPage = line.visibleItems.map(\.id)
            let newID = try XCTUnwrap(line.hang(pictures[15], quietly: true))
            line.showPage(2)
            XCTAssertEqual(line.visibleItems.map(\.url), [pictures[0]])
            line.showPage(1)
            XCTAssertEqual(line.visibleItems.map(\.id), originalPage)
            XCTAssertEqual(line.pendingCount, 1)
            XCTAssertFalse(line.visibleItems.contains { $0.id == newID })
            line.showLatest()
            XCTAssertEqual(line.visibleItems.first?.id, newID)
            XCTAssertEqual(line.pendingCount, 0)
        }
    }

    @MainActor
    func testRepeatedExistingNoteIsPendingOnceAndLatestCanFindItWithoutReordering() throws {
        try withTemporaryLine { line, pictures, folder in
            let text = "已有文字不打断浏览 🧺\n保留原顺序"
            let noteID = try XCTUnwrap(line.hangCopiedText(text, in: folder))
            for picture in pictures.prefix(19) { line.hang(picture, quietly: true) }
            line.showPage(0)
            let visibleIDs = line.visibleItems.map(\.id)
            let storedIDs = line.liveItems.map(\.id)
            let noteCount = Settings.current.notes.count

            XCTAssertEqual(line.hangCopiedText(text, in: folder), noteID)
            XCTAssertEqual(line.hangCopiedText(text, in: folder), noteID)

            XCTAssertEqual(line.visibleItems.map(\.id), visibleIDs)
            XCTAssertEqual(line.pendingCount, 1, "The badge must count unique updated content rather than repeated copy events")
            XCTAssertEqual(line.liveItems.map(\.id), storedIDs)
            XCTAssertEqual(Settings.current.notes.count, noteCount)

            line.showLatest()

            XCTAssertEqual(line.pageIndex, 2, "Latest must find the most recently copied item even if it is an older deduplicated note")
            XCTAssertTrue(line.visibleItems.contains { $0.id == noteID })
            XCTAssertEqual(line.pendingCount, 0)
            XCTAssertEqual(line.liveItems.map(\.id), storedIDs)
        }
    }

    @MainActor
    func testPendingCountRemovesEvictedPendingCardsAndNeverGrowsPastRetainedContent() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(2)
            let visibleIDs = line.visibleItems.map(\.id)
            for picture in pictures[20...39] { line.hang(picture, quietly: true) }
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.visibleItems.map(\.id), visibleIDs)
            XCTAssertEqual(line.pendingCount, 14, "Only pending cards still hanging should be counted")
            XCTAssertEqual(line.pageCount, 1, "Empty saved pages should disappear without moving the current cards")
            XCTAssertEqual(line.pageIndex, 0)
            line.showLatest()
            XCTAssertEqual(line.pageCount, 3)
            XCTAssertEqual(line.pendingCount, 0)
            XCTAssertEqual(line.visibleItems.map(\.url), Array(pictures[33...39].reversed()))
        }
    }

    @MainActor
    func testOnlyOneTemporaryExtraIsKeptWhenEveryOrdinaryCardIsProtected() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            for item in line.liveItems { line.togglePin(item.id) }
            line.beginBrowsing()
            let firstExtraID = try XCTUnwrap(line.hang(pictures[20], quietly: true))
            XCTAssertEqual(line.liveCount, 21)
            XCTAssertEqual(line.pendingCount, 1)
            line.showLatest()
            XCTAssertTrue(line.visibleItems.contains { $0.id == firstExtraID })

            let nextExtraID = try XCTUnwrap(line.hang(pictures[21], quietly: true))

            XCTAssertEqual(line.liveCount, 21, "Taking a look at the extra card must not allow unlimited overflow")
            XCTAssertTrue(line.item(firstExtraID)?.falling == true)
            XCTAssertTrue(line.item(nextExtraID)?.falling == false)
            XCTAssertEqual(line.liveItems.filter(\.pinned).count, 20)
            XCTAssertEqual(line.pendingCount, 1)
            line.showLatest()
            XCTAssertEqual(line.visibleItems.first?.id, nextExtraID)
        }
    }

    @MainActor
    func testMovingFrozenPageDoesNotReorderPendingOrOtherVisibleGroups() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(2)
            let visible = line.visibleItems
            let pendingID = try XCTUnwrap(line.hang(pictures[20], quietly: true))
            let before = line.liveItems.filter { !Set(visible.map(\.id)).contains($0.id) }.map(\.id)
            let movedID = try XCTUnwrap(visible.first?.id)

            line.moveVisible(movedID, to: 3)

            XCTAssertEqual(line.visibleItems.map(\.id), [visible[1].id, visible[2].id, visible[3].id, visible[0].id, visible[4].id, visible[5].id])
            XCTAssertEqual(line.liveItems.filter { !Set(visible.map(\.id)).contains($0.id) }.map(\.id), before)
            XCTAssertEqual(line.liveItems.last?.id, pendingID)
            XCTAssertEqual(line.pendingCount, 1)
        }
    }

    @MainActor
    func testCaptureAfterAllBrowsedCardsAreRemovedIsImmediatelyVisible() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(8) { line.hang(picture, quietly: true) }
            line.showPage(1)
            for item in line.liveItems { line.drop(item.id, quietly: true) }
            XCTAssertTrue(line.isBrowsing)
            XCTAssertEqual(line.visibleItems.count, 0)

            let newID = try XCTUnwrap(line.hang(pictures[8], quietly: true))

            XCTAssertTrue(line.isBrowsing, "An empty line must not end the user's browsing visit")
            XCTAssertEqual(line.visibleItems.map(\.id), [newID], "No old card needs protecting, so the new card must be immediately reachable")
            XCTAssertEqual(line.pendingCount, 0)
        }
    }

    @MainActor
    func testLatestFallsBackToNewestRemainingCardAfterItsTargetIsRemoved() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(8) { line.hang(picture, quietly: true) }
            let removedID = try XCTUnwrap(line.latestCaptureID)
            line.drop(removedID, quietly: true)

            line.showLatest()

            XCTAssertEqual(line.latestCaptureID, line.liveItems.last?.id)
            XCTAssertEqual(line.visibleItems.first?.url, pictures[6])
            XCTAssertFalse(line.latestCaptureID == removedID)
            for item in line.liveItems { line.drop(item.id, quietly: true) }
            line.showLatest()
            XCTAssertNil(line.latestCaptureID)
        }
    }
}
