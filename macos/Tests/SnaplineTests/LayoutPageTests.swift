import AppKit
import XCTest
@testable import Snapline

final class LayoutPageTests: XCTestCase {
    @MainActor
    private func withTwentyMixedCards(_ body: (Line) throws -> Void) throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        Settings.current.soundOn = false
        defer {
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnaplineLayoutPages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                   pixelsWide: 16, pixelsHigh: 12,
                                                   bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let line = Line(persist: false)
        line.maxItems = 20
        line.pageSize = Layout.pageSize(for: 1470)
        line.layoutWidth = 1470
        for index in 0..<20 {
            if index.isMultiple(of: 2) {
                XCTAssertNotNil(line.hangCopiedText("布局便签 \(index) 🧺\n第二行", in: folder))
            } else {
                let picture = folder.appendingPathComponent("picture-\(index).png")
                try png.write(to: picture)
                XCTAssertNotNil(line.hang(picture, quietly: true))
            }
        }
        try body(line)
    }

    @MainActor
    func testTwentyMixedCardsStayInsideScreenAndDoNotOverlapOnEveryPage() async throws {
        try withTwentyMixedCards { line in
            let width: CGFloat = 1470
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.liveItems.filter(\.isNote).count, 10)
            XCTAssertEqual(line.pageSize, 7)
            XCTAssertEqual(line.pageCount, 3)
            var visited = Set<UUID>()
            for page in 0..<line.pageCount {
                line.showPage(page)
                let positions = Layout.positions(for: line, width: width)
                let visibleIDs = Set(line.visibleItems.map(\.id))
                XCTAssertEqual(Set(positions.keys), visibleIDs,
                               "Only the current page may contribute card coordinates")
                XCTAssertTrue(visited.isDisjoint(with: visibleIDs),
                              "Pages must not repeat a retained card")
                visited.formUnion(visibleIDs)
                let centers = positions.values.sorted()
                for center in centers {
                    XCTAssertTrue(center - Layout.cardWidth / 2 >= 0,
                                  "The full-size card must fit inside the left edge")
                    XCTAssertTrue(center + Layout.cardWidth / 2 <= width,
                                  "The full-size card must fit inside the right edge")
                }
                for (left, right) in zip(centers, centers.dropFirst()) {
                    XCTAssertTrue(right - left >= Layout.cardWidth,
                                  "Cards on the same page must not overlap")
                }
            }
            XCTAssertEqual(visited, Set(line.liveItems.map(\.id)),
                           "All twenty retained text and image cards must be accessible by paging")
        }
    }

    @MainActor
    func testMultiplePagesUseReadableSpacingEvenWhenManualSpotsOverlap() async throws {
        try withTwentyMixedCards { line in
            Settings.current.autoArrange = false
            for item in line.liveItems { line.setSpot(item.id, 0.5, save: false) }
            for page in 0..<line.pageCount {
                line.showPage(page)
                let positions = Layout.positions(for: line, width: 1470)
                let centers = positions.values.sorted()
                XCTAssertEqual(centers.count, line.visibleItems.count)
                XCTAssertEqual(Set(centers).count, centers.count,
                               "Manual spots must not stack multiple paged cards at the same coordinate")
                for (left, right) in zip(centers, centers.dropFirst()) {
                    XCTAssertTrue(right - left >= Layout.cardWidth)
                }
            }
        }
    }

    @MainActor
    func testReducingOverlappingManualCardsToOnePageKeepsAllRemainingCardsAccessible() async throws {
        try withTwentyMixedCards { line in
            Settings.current.autoArrange = false
            for item in line.liveItems { line.setSpot(item.id, 0.5, save: false) }
            let original = line.liveItems
            let remainingIDs = Set(original.suffix(6).map(\.id))
            line.showPage(2)
            for item in original.prefix(14) { line.drop(item.id, quietly: true) }

            XCTAssertEqual(line.liveCount, 6)
            XCTAssertEqual(line.pageCount, 1)
            XCTAssertEqual(line.pageIndex, 0, "Removing a page must return to a valid remaining page")
            XCTAssertEqual(Set(line.visibleItems.map(\.id)), remainingIDs,
                           "All remaining cards must be reachable after the paged line becomes one page")
            let positions = Layout.positions(for: line, width: 1470)
            XCTAssertEqual(Set(positions.keys), remainingIDs)
            let centers = positions.values.sorted()
            for center in centers {
                XCTAssertTrue(center - Layout.cardWidth / 2 >= 0)
                XCTAssertTrue(center + Layout.cardWidth / 2 <= 1470)
            }
            for (left, right) in zip(centers, centers.dropFirst()) {
                XCTAssertTrue(right - left >= Layout.cardWidth,
                              "Manual spots inherited from multiple pages must not stack the remaining cards")
            }
        }
    }
}
