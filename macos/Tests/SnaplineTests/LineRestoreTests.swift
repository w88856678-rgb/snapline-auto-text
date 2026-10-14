import AppKit
import XCTest
@testable import Snapline

final class LineRestoreTests: XCTestCase {
    @MainActor
    private func withTemporaryPictures(count: Int, _ body: ([URL], URL) throws -> Void) throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        defer {
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                   pixelsWide: 16, pixelsHigh: 12,
                                                   bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let pictures = (0..<count).map { folder.appendingPathComponent("picture-\($0).png") }
        for picture in pictures { try png.write(to: picture) }
        try body(pictures, folder)
    }

    @MainActor
    func testRestorePreservesPinsAndManualPositionsBeforeSaving() throws {
        try withTemporaryPictures(count: 3) { pictures, folder in
            let missing = folder.appendingPathComponent("missing.png").path
            let pinned = [pictures[0].path, pictures[2].path]
            let spots = Dictionary(uniqueKeysWithValues: zip(pictures.map(\.path), [0.12, 0.51, 0.87]))
            Settings.current.pegged = [pictures[0].path, missing, pictures[1].path, pictures[2].path]
            Settings.current.pinnedPaths = pinned + [missing]
            Settings.current.spots = spots.merging([missing: 0.2]) { first, _ in first }

            let line = Line()

            XCTAssertEqual(line.items.map(\.url), pictures, "All existing pictures must return in their saved order")
            XCTAssertTrue(line.items.allSatisfy { $0.used && !$0.falling })
            XCTAssertEqual(line.items.filter(\.pinned).map(\.url.path), pinned, "Restoring earlier cards must not erase the pins of later cards")
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: line.items.compactMap { item in item.spot.map { (item.url.path, $0) } }), spots)
            XCTAssertEqual(Settings.current.pegged, pictures.map(\.path))
            XCTAssertEqual(Settings.current.pinnedPaths, pinned, "The completed restore must save its restored pin state")
            XCTAssertEqual(Settings.current.spots, spots, "The completed restore must save the original manual positions and remove only missing files")
        }
    }

    @MainActor
    func testRestoreKeepsOverCapacityCardsUntilNextCaptureAndProtectsPins() throws {
        try withTemporaryPictures(count: 24) { pictures, _ in
            let restored = Array(pictures.prefix(23))
            let pinned = [pictures[0].path, pictures[1].path, pictures[22].path]
            Settings.current.pegged = restored.map(\.path)
            Settings.current.pinnedPaths = pinned

            let line = Line()

            XCTAssertEqual(line.maxItems, 20, "Restoration must return the original capacity after loading saved cards")
            XCTAssertEqual(line.liveCount, 23, "Restoration must not discard cards saved on a wider display")
            XCTAssertEqual(line.pageIndex, 0, "Restoring saved cards must start on the first page")
            XCTAssertEqual(line.items.filter(\.pinned).map(\.url.path), pinned)
            XCTAssertEqual(Settings.current.pegged, restored.map(\.path))

            let newID = try XCTUnwrap(line.hang(pictures[23], quietly: true))

            XCTAssertEqual(line.liveCount, 20, "The next capture must apply the real capacity")
            XCTAssertEqual(line.pageIndex, 2, "A new capture must reveal its page after restoring an over-capacity line")
            XCTAssertTrue(line.item(newID)?.falling == false)
            XCTAssertEqual(line.items.filter { !$0.falling && $0.pinned }.map(\.url.path), pinned)
            let expectedLive = [pictures[0], pictures[1]] + Array(pictures[6...23])
            XCTAssertEqual(line.items.filter { !$0.falling }.map(\.url), expectedLive, "Only the oldest unpinned restored cards should fall")
            XCTAssertEqual(Settings.current.pegged, expectedLive.map(\.path))
            XCTAssertEqual(Settings.current.pinnedPaths, pinned)
        }
    }
}
