import AppKit
import XCTest
@testable import Snapline

final class TwentyItemCapacityTests: XCTestCase {
    @MainActor
    private func withTemporaryPictures(_ body: (URL, Data) throws -> Void) throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        Settings.current.soundOn = false
        defer {
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineTwentyItemsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                   pixelsWide: 16, pixelsHigh: 12,
                                                   bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try body(folder, png)
    }

    @MainActor
    func testFirstTwentyMixedCardsRemainAndTwentyFirstReplacesOldestUnpinnedWithoutDeletingFiles() throws {
        try withTemporaryPictures { folder, png in
            let line = Line()
            XCTAssertEqual(line.maxItems, 20)
            var originalIDs: [UUID] = []
            for index in 0..<20 {
                let id: UUID
                if index.isMultiple(of: 2) {
                    let picture = folder.appendingPathComponent("picture-\(index).png")
                    try png.write(to: picture)
                    id = try XCTUnwrap(line.hang(picture, quietly: true))
                } else {
                    id = try XCTUnwrap(line.hangCopiedText("第 \(index + 1) 项文字 🧺\n原始全文", in: folder))
                }
                originalIDs.append(id)
                if index == 0 || index == 4 { line.togglePin(id) }
            }
            let originalURLs = line.items.map(\.url)
            let pinnedPaths = [originalURLs[0].path, originalURLs[4].path]
            XCTAssertEqual(line.liveCount, 20, "Images and copied text share the same twenty-card capacity")
            XCTAssertEqual(line.items.filter { !$0.falling }.map(\.id), originalIDs, "Every one of the first twenty cards must remain visible")
            XCTAssertEqual(line.items.filter(\.isNote).count, 10)
            XCTAssertEqual(Settings.current.pegged, originalURLs.map(\.path))

            let latestText = "第 21 项新复制的文字 ✅\n完整保留"
            let latestID = try XCTUnwrap(line.hangCopiedText(latestText, in: folder))
            let latest = try XCTUnwrap(line.item(latestID))

            XCTAssertEqual(line.liveCount, 20)
            XCTAssertTrue(line.item(originalIDs[1])?.falling == true, "The oldest unpinned card must be replaced, even when it is a text note")
            XCTAssertEqual(line.items.filter { !$0.falling }.map(\.id), [originalIDs[0]] + Array(originalIDs.dropFirst(2)) + [latestID])
            XCTAssertEqual(line.items.filter { !$0.falling && $0.pinned }.map(\.url.path), pinnedPaths, "Pinned cards must never be evicted")
            XCTAssertFalse(latest.falling)
            XCTAssertEqual(Notes.get(latest.url)?.text, latestText)
            XCTAssertEqual(Notes.get(originalURLs[1])?.text, "第 2 项文字 🧺\n原始全文", "Capacity eviction must preserve a note's original text")
            XCTAssertTrue((originalURLs + [latest.url]).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Taking a card off the full line must not delete its image or text-note file")
            XCTAssertEqual(Settings.current.pegged, ([originalURLs[0]] + Array(originalURLs.dropFirst(2)) + [latest.url]).map(\.path))
            XCTAssertEqual(Settings.current.pinnedPaths, pinnedPaths)
        }
    }

    @MainActor
    func testLegacySettingsRestoreTwentyMixedCardsWithoutAddingCapacityPreference() throws {
        try withTemporaryPictures { folder, png in
            var pictures: [URL] = []
            for index in 0..<20 {
                if index.isMultiple(of: 2) {
                    let picture = folder.appendingPathComponent("legacy-picture-\(index).png")
                    try png.write(to: picture)
                    pictures.append(picture)
                } else {
                    pictures.append(Notes.create(color: "green", text: "已有便签 \(index)\n保留原文", in: folder))
                }
            }
            let pinnedPaths = [pictures[1].path, pictures[18].path]
            let spots = Dictionary(uniqueKeysWithValues: pictures.enumerated().map { ($0.element.path, Double($0.offset) / 20) })
            Settings.current.pegged = pictures.map(\.path)
            Settings.current.pinnedPaths = pinnedPaths
            Settings.current.spots = spots
            Settings.current.autoHangCopiedText = false
            Settings.current.showOverFullScreen = true
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.current)) as? [String: Any])
            legacy.removeValue(forKey: "catchClipboardText")
            legacy.removeValue(forKey: "fullScreenOverlay")
            XCTAssertNil(legacy["maxItems"], "The capacity increase must not require a new setting in older files")
            Settings.current = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacy))

            let line = Line()

            XCTAssertEqual(line.maxItems, 20)
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertEqual(line.items.map(\.url), pictures)
            XCTAssertEqual(line.items.filter(\.isNote).count, 10)
            XCTAssertEqual(line.items.filter(\.pinned).map(\.url.path), pinnedPaths)
            XCTAssertEqual(Settings.current.spots, spots)
            XCTAssertEqual(Notes.get(pictures[1])?.text, "已有便签 1\n保留原文")
            XCTAssertTrue(Settings.current.autoHangCopiedText)
            XCTAssertFalse(Settings.current.showOverFullScreen)
            XCTAssertTrue(pictures.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
    }
}
