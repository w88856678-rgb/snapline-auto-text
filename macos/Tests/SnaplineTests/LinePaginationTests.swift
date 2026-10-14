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
        let pictures = (0..<21).map { folder.appendingPathComponent("picture-\($0).png") }
        for picture in pictures { try png.write(to: picture) }
        try body(Line(persist: false), pictures, folder)
    }

    @MainActor
    func testTwentyCardsUseSevenSevenSixPagesAndNewCaptureShowsItsPage() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            XCTAssertEqual(line.pageSize, 7)
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.pageCount, 3)
            XCTAssertEqual(line.pageIndex, 2, "Each new capture must reveal the page containing that card")
            for page in 0..<3 {
                line.showPage(page)
                XCTAssertEqual(line.pageStart, page * 7)
                XCTAssertEqual(line.visibleItems.map(\.url), Array(pictures.dropFirst(page * 7).prefix(page == 2 ? 6 : 7)))
            }

            line.showPage(0)
            let latestID = try XCTUnwrap(line.hang(pictures[20], quietly: true))

            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.pageIndex, 2, "A capture on a full line must jump to its page after eviction")
            XCTAssertEqual(line.visibleItems.count, 6)
            XCTAssertTrue(line.visibleItems.contains { $0.id == latestID })
            XCTAssertEqual(line.liveItems.map(\.url), Array(pictures.dropFirst()))
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
            XCTAssertEqual(line.pageIndex, 2)
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
            line.pageSize = 7
            XCTAssertEqual(line.pageIndex, 1)
            line.pageSize = -7
            XCTAssertEqual(line.pageSize, 1, "Invalid page sizes must never cause division by zero or negative slicing")
            XCTAssertEqual(line.visibleItems.count, 1)
        }
    }

    @MainActor
    func testMovingWithinPageKeepsPageIndexAndUsesLiveOffsets() throws {
        try withTemporaryLine { line, pictures, _ in
            for picture in pictures.prefix(20) { line.hang(picture, quietly: true) }
            line.showPage(1)
            let firstVisible = try XCTUnwrap(line.visibleItems.first)

            line.move(firstVisible.id, to: line.pageStart + 3)

            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertEqual(line.pageStart, 7)
            XCTAssertEqual(line.visibleItems.map(\.url), [pictures[8], pictures[9], pictures[10], pictures[7], pictures[11], pictures[12], pictures[13]])
        }
    }
}
