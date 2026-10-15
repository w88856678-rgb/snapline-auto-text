import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snapline

final class ClipboardImageIntegrationTests: XCTestCase {
    /// Every callback writes into this test's temporary directory. Never use
    /// the general clipboard, the real Inbox, or the persisted user settings.
    @MainActor
    private func withEnvironment(_ body: (NSPasteboard, URL) async throws -> Void) async throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        let pasteboard = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineImageTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await body(pasteboard, folder)
    }

    @MainActor
    private func png(_ value: Int) throws -> Data {
        let pixel: [UInt8] = [UInt8(value % 255), UInt8((value * 37) % 255), UInt8((value * 71) % 255), 255]
        let bytes = Array(repeating: pixel, count: 16 * 12).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        let image = try XCTUnwrap(CGImage(width: 16, height: 12, bitsPerComponent: 8,
                                         bitsPerPixel: 32, bytesPerRow: 16 * 4, space: space,
                                         bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                         shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @MainActor
    private func copyImage(_ data: Data, to pasteboard: NSPasteboard, withWebMetadata: Bool = false) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(data, forType: .png))
        if withWebMetadata {
            XCTAssertTrue(pasteboard.setString("https://example.invalid/copied-picture.png", forType: .string))
            XCTAssertTrue(pasteboard.setString("https://example.invalid/copied-picture.png", forType: .URL))
            XCTAssertTrue(pasteboard.setString("<img src=\"https://example.invalid/copied-picture.png\">", forType: .html))
        }
    }

    @MainActor
    private func waitForCapture() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor
    func testCopiedWebImageIsSavedAndHungWithoutCreatingURLNote() async throws {
        try await withEnvironment { pasteboard, folder in
            let line = Line(persist: false)
            var captures: [(URL, CGSize)] = []
            var texts: [String] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, size in
                                               captures.append((url, size))
                                               line.hang(url, quietly: true)
                                           }, onText: { texts.append($0) }, recentlyHungFromFile: { _ in false })
            watcher.textEnabled = true
            defer { watcher.stop() }
            let data = try png(1)
            copyImage(data, to: pasteboard, withWebMetadata: true)
            watcher.poll()
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(captures.count, 1)
            XCTAssertTrue(texts.isEmpty, "A picture's accompanying URL is metadata, not a copied text note")
            let capture = try XCTUnwrap(captures.first)
            XCTAssertEqual(capture.0.deletingLastPathComponent(), folder)
            XCTAssertEqual(capture.1, CGSize(width: 16, height: 12))
            XCTAssertEqual(capture.0.pathExtension, "png")
            let saved = try XCTUnwrap(ClipboardImage(data: Data(contentsOf: capture.0)))
            let original = try XCTUnwrap(ClipboardImage(data: data))
            XCTAssertEqual(saved.fingerprint, original.fingerprint)
            XCTAssertEqual(line.liveCount, 1)
            XCTAssertEqual(line.liveItems.first?.url, capture.0)
            XCTAssertEqual(line.visibleItems.first?.id, line.latestCaptureID)
            XCTAssertFalse(line.liveItems.first?.isNote == true)
        }
    }

    @MainActor
    func testRapidSameSizeDifferentImagesBothKeepTheirOwnSnapshots() async throws {
        try await withEnvironment { pasteboard, folder in
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) }, onText: { _ in XCTFail("Images must not become notes") },
                                           recentlyHungFromFile: { _ in false })
            defer { watcher.stop() }
            let first = try png(2)
            let second = try png(3)
            copyImage(first, to: pasteboard)
            watcher.poll()
            copyImage(second, to: pasteboard)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(captures.count, 2, "A later clipboard change must not cancel the earlier image")
            XCTAssertEqual(Set(captures).count, 2, "Captures in the same second still need unique filenames")
            let firstImage = try XCTUnwrap(ClipboardImage(data: first))
            let secondImage = try XCTUnwrap(ClipboardImage(data: second))
            XCTAssertEqual(firstImage.size, secondImage.size)
            XCTAssertNotEqual(firstImage.fingerprint, secondImage.fingerprint)
            let saved = try captures.map { url in
                try XCTUnwrap(ClipboardImage(data: Data(contentsOf: url))).fingerprint
            }
            XCTAssertEqual(Set(saved), Set([firstImage.fingerprint, secondImage.fingerprint]))
        }
    }

    @MainActor
    func testTextCopiedImmediatelyAfterImageDoesNotLoseEitherContent() async throws {
        try await withEnvironment { pasteboard, folder in
            let line = Line(persist: false)
            var imageURLs: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in
                                               imageURLs.append(url)
                                               line.hang(url, quietly: true)
                                           }, onText: { line.hangCopiedText($0, in: folder) }, recentlyHungFromFile: { _ in false })
            watcher.textEnabled = true
            defer { watcher.stop() }
            copyImage(try png(4), to: pasteboard)
            watcher.poll()
            copyTestText("图片之后复制的文字 🧺\n第二行", to: pasteboard)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(imageURLs.count, 1)
            XCTAssertEqual(line.liveCount, 2)
            XCTAssertEqual(line.liveItems.filter(\.isNote).count, 1)
            XCTAssertEqual(line.liveItems.compactMap { Notes.get($0.url)?.text }, ["图片之后复制的文字 🧺\n第二行"])
            XCTAssertTrue(imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            let textCard = try XCTUnwrap(line.liveItems.first(where: \.isNote))
            let imageCard = try XCTUnwrap(line.liveItems.first(where: { !$0.isNote }))
            XCTAssertEqual(line.liveItems.map(\.id), [imageCard.id, textCard.id])
            XCTAssertEqual(line.latestCaptureID, textCard.id, "The image's delivery delay must not make it newer than the text copied afterwards")
            XCTAssertEqual(line.visibleItems.first?.id, textCard.id)
        }
    }

    @MainActor
    func testImageTextImageCopiesKeepTheirOrderAndTheLastPictureIsLatest() async throws {
        try await withEnvironment { pasteboard, folder in
            let line = Line(persist: false)
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in
                                               captures.append(url)
                                               line.hang(url, quietly: true)
                                           }, onText: { line.hangCopiedText($0, in: folder) }, recentlyHungFromFile: { _ in false })
            watcher.textEnabled = true
            defer { watcher.stop() }
            let firstData = try png(50)
            let lastData = try png(51)
            copyImage(firstData, to: pasteboard)
            watcher.poll()
            copyTestText("两张图片之间复制的文字", to: pasteboard)
            watcher.poll()
            copyImage(lastData, to: pasteboard)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(captures.count, 2)
            XCTAssertEqual(line.liveCount, 3)
            XCTAssertEqual(line.liveItems.map { Notes.get($0.url)?.text ?? "图片" }, ["图片", "两张图片之间复制的文字", "图片"])
            let firstCard = try XCTUnwrap(line.liveItems.first)
            let lastCard = try XCTUnwrap(line.liveItems.last)
            let firstImage = try XCTUnwrap(ClipboardImage(data: Data(contentsOf: firstCard.url)))
            let lastImage = try XCTUnwrap(ClipboardImage(data: Data(contentsOf: lastCard.url)))
            let expectedFirst = try XCTUnwrap(ClipboardImage(data: firstData))
            let expectedLast = try XCTUnwrap(ClipboardImage(data: lastData))
            XCTAssertEqual(firstImage.fingerprint, expectedFirst.fingerprint)
            XCTAssertEqual(lastImage.fingerprint, expectedLast.fingerprint)
            XCTAssertEqual(line.latestCaptureID, lastCard.id)
            XCTAssertEqual(line.visibleItems.first?.id, lastCard.id)
        }
    }

    @MainActor
    func testTextCopiedAsTheImageIsDeliveredStaysNewerThanAlreadyQueuedText() async throws {
        try await withEnvironment { pasteboard, folder in
            let line = Line(persist: false)
            var watcher: ClipboardWatcher?
            watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                       onCapture: { url, _ in
                                           line.hang(url, quietly: true)
                                           // Deliver a further copy while the first image's
                                           // callback runs and the earlier text is still queued.
                                           // This is deterministic and needs no boundary sleep.
                                           copyTestText("图片落盘时新复制的文字", to: pasteboard)
                                           watcher?.poll()
                                       }, onText: { line.hangCopiedText($0, in: folder) }, recentlyHungFromFile: { _ in false })
            watcher?.textEnabled = true
            defer {
                watcher?.stop()
                watcher = nil
            }
            copyImage(try png(52), to: pasteboard)
            watcher?.poll()
            copyTestText("已经在等待中的文字", to: pasteboard)
            watcher?.poll()
            try await waitForCapture()

            XCTAssertEqual(line.liveCount, 3)
            XCTAssertEqual(line.liveItems.map { Notes.get($0.url)?.text ?? "图片" }, ["图片", "已经在等待中的文字", "图片落盘时新复制的文字"])
            let latest = try XCTUnwrap(line.liveItems.last)
            XCTAssertEqual(Notes.get(latest.url)?.text, "图片落盘时新复制的文字")
            XCTAssertEqual(line.latestCaptureID, latest.id, "An earlier queued text delivery must never take Latest back from a later copy")
            XCTAssertEqual(line.visibleItems.first?.id, latest.id)
        }
    }

    @MainActor
    func testImageSwitchOffIgnoresImageMetadataWhileTextCaptureStillWorks() async throws {
        try await withEnvironment { pasteboard, folder in
            var texts: [String] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { _, _ in XCTFail("Image capture is disabled") },
                                           onText: { texts.append($0) }, recentlyHungFromFile: { _ in false })
            watcher.enabled = false
            watcher.textEnabled = true
            defer { watcher.stop() }
            copyImage(try png(5), to: pasteboard, withWebMetadata: true)
            watcher.poll()
            copyTestText("只收集普通文字", to: pasteboard)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(texts, ["只收集普通文字"])
            let savedFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertTrue(savedFiles.isEmpty)
        }
    }

    @MainActor
    func testTextSwitchOffDoesNotDisableImages() async throws {
        try await withEnvironment { pasteboard, folder in
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) },
                                           onText: { _ in XCTFail("Text capture is disabled") }, recentlyHungFromFile: { _ in false })
            watcher.textEnabled = false
            defer { watcher.stop() }
            copyImage(try png(6), to: pasteboard, withWebMetadata: true)
            watcher.poll()
            copyTestText("不会挂上的文字", to: pasteboard)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(captures.count, 1)
            let savedFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(savedFiles.count, 1)
        }
    }

    @MainActor
    func testOwnProtectedAndDamagedImagesNeverCreateCardsOrMetadataNotes() async throws {
        try await withEnvironment { pasteboard, folder in
            var captures: [URL] = []
            var texts: [String] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) }, onText: { texts.append($0) },
                                           recentlyHungFromFile: { _ in false })
            watcher.textEnabled = true
            defer { watcher.stop() }
            let image = try png(7)
            for marker in [ClipboardContent.ownCopyType,
                           NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                           NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                           NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")] {
                copyImage(image, to: pasteboard, withWebMetadata: true)
                XCTAssertTrue(pasteboard.setData(Data(), forType: marker))
                watcher.poll()
            }
            copyImage(Data("not an encoded image".utf8), to: pasteboard, withWebMetadata: true)
            watcher.poll()
            try await waitForCapture()
            XCTAssertTrue(captures.isEmpty)
            XCTAssertTrue(texts.isEmpty)
            let savedFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertTrue(savedFiles.isEmpty)

            copyImage(image, to: pasteboard)
            watcher.poll()
            try await waitForCapture()
            XCTAssertEqual(captures.count, 1, "Ignoring an invalid or protected copy must not disable later ordinary images")
        }
    }

    @MainActor
    func testStartAndReenableDoNotReplayOldImages() async throws {
        try await withEnvironment { pasteboard, folder in
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) }, onText: { _ in }, recentlyHungFromFile: { _ in false })
            defer { watcher.stop() }
            copyImage(try png(8), to: pasteboard)
            watcher.start()
            watcher.poll()
            try await waitForCapture()
            XCTAssertTrue(captures.isEmpty)

            watcher.enabled = false
            copyImage(try png(9), to: pasteboard)
            watcher.enabled = true
            watcher.poll()
            try await waitForCapture()
            XCTAssertTrue(captures.isEmpty)

            copyImage(try png(10), to: pasteboard)
            watcher.poll()
            try await waitForCapture()
            XCTAssertEqual(captures.count, 1)
        }
    }

    @MainActor
    func testDisabledAndStoppedWatchersCancelAlreadySnapshottedImages() async throws {
        try await withEnvironment { pasteboard, folder in
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) }, onText: { _ in }, recentlyHungFromFile: { _ in false })
            defer { watcher.stop() }
            copyImage(try png(11), to: pasteboard)
            watcher.poll()
            watcher.enabled = false
            watcher.enabled = true
            try await waitForCapture()
            XCTAssertTrue(captures.isEmpty)

            copyImage(try png(12), to: pasteboard)
            watcher.poll()
            watcher.stop()
            try await waitForCapture()
            XCTAssertTrue(captures.isEmpty)
            let savedFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertTrue(savedFiles.isEmpty)
        }
    }

    @MainActor
    func testEachCaptureSwitchPreservesAlreadyQueuedCopiesOfTheOtherKind() async throws {
        try await withEnvironment { pasteboard, folder in
            var captures: [URL] = []
            var texts: [String] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) }, onText: { texts.append($0) },
                                           recentlyHungFromFile: { _ in false })
            watcher.textEnabled = true
            defer { watcher.stop() }

            copyImage(try png(60), to: pasteboard)
            watcher.poll()
            copyTestText("关图片之后仍应交付的排队文字", to: pasteboard)
            watcher.poll()
            watcher.enabled = false
            try await waitForCapture()
            XCTAssertTrue(captures.isEmpty)
            XCTAssertEqual(texts, ["关图片之后仍应交付的排队文字"])

            watcher.enabled = true
            let imageData = try png(61)
            copyImage(imageData, to: pasteboard)
            watcher.poll()
            copyTestText("关文字之后应取消的排队文字", to: pasteboard)
            watcher.poll()
            watcher.textEnabled = false
            try await waitForCapture()
            XCTAssertEqual(captures.count, 1, "Turning off text capture must preserve a pending image")
            XCTAssertEqual(texts, ["关图片之后仍应交付的排队文字"])
            let saved = try XCTUnwrap(captures.first)
            let actual = try XCTUnwrap(ClipboardImage(data: Data(contentsOf: saved)))
            let expected = try XCTUnwrap(ClipboardImage(data: imageData))
            XCTAssertEqual(actual.fingerprint, expected.fingerprint)
        }
    }

    @MainActor
    func testFileWatcherDeduplicatesByImageContentAtCaptureTime() async throws {
        try await withEnvironment { pasteboard, folder in
            let recent = RecentImageCaptures()
            let firstData = try png(13)
            let secondData = try png(14)
            let first = try XCTUnwrap(ClipboardImage(data: firstData))
            let second = try XCTUnwrap(ClipboardImage(data: secondData))
            XCTAssertEqual(first.size, second.size)
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in captures.append(url) }, onText: { _ in },
                                           recentlyHungFromFile: { recent.contains($0) })
            defer { watcher.stop() }
            copyImage(firstData, to: pasteboard)
            watcher.poll()
            // The screenshot file watcher may finish after the clipboard
            // snapshot, while this delayed capture is waiting to be written.
            recent.record(first)
            copyImage(secondData, to: pasteboard)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(captures.count, 1, "Only the identical saved screenshot should be suppressed")
            let saved = try XCTUnwrap(captures.first)
            let savedImage = try XCTUnwrap(ClipboardImage(data: Data(contentsOf: saved)))
            XCTAssertEqual(savedImage.fingerprint, second.fingerprint)
        }
    }

    @MainActor
    func testRecentFileImagesExpireAndUnrecordedCopiesAreNeverRemembered() throws {
        let recent = RecentImageCaptures()
        let first = try XCTUnwrap(ClipboardImage(data: png(15)))
        let second = try XCTUnwrap(ClipboardImage(data: png(16)))
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(first.size, second.size)
        XCTAssertFalse(recent.contains(first, now: time))
        XCTAssertFalse(recent.contains(first, now: time.addingTimeInterval(1)), "Reading the cache must not record a clipboard image")
        recent.record(first, at: time)
        XCTAssertTrue(recent.contains(first, now: time.addingTimeInterval(4)))
        XCTAssertFalse(recent.contains(second, now: time.addingTimeInterval(4)), "Matching dimensions do not mean matching image content")
        XCTAssertFalse(recent.contains(first, now: time.addingTimeInterval(6)))
        recent.record(first, at: time.addingTimeInterval(7))
        XCTAssertTrue(recent.contains(first, now: time.addingTimeInterval(8)), "A later saved capture gets a fresh deduplication window")
    }

    @MainActor
    func testCaptureCacheReturnsOnlyTheMatchingSourceURLAndExpiresIt() async throws {
        try await withEnvironment { _, folder in
            let recent = RecentImageCaptures()
            let first = try XCTUnwrap(ClipboardImage(data: png(62)))
            let second = try XCTUnwrap(ClipboardImage(data: png(63)))
            let fileURL = folder.appendingPathComponent("file-capture.png")
            let clipboardURL = folder.appendingPathComponent("clipboard-capture.png")
            let replacementURL = folder.appendingPathComponent("later-file-capture.png")
            let time = Date(timeIntervalSince1970: 1_700_000_000)

            recent.record(first, url: fileURL, source: .file, at: time)
            XCTAssertEqual(recent.matchingURL(first, source: .file, now: time), fileURL)
            XCTAssertNil(recent.matchingURL(first, source: .clipboard, now: time))
            recent.record(second, url: clipboardURL, source: .clipboard, at: time.addingTimeInterval(1))
            XCTAssertEqual(recent.matchingURL(second, source: .clipboard, now: time.addingTimeInterval(1)), clipboardURL)
            XCTAssertNil(recent.matchingURL(second, source: .file, now: time.addingTimeInterval(1)))
            XCTAssertEqual(recent.matchingURL(first, source: .file, now: time.addingTimeInterval(1)), fileURL)

            recent.record(second, url: replacementURL, source: .file, at: time.addingTimeInterval(2))
            XCTAssertEqual(recent.matchingURL(second, source: .file, now: time.addingTimeInterval(3)), replacementURL)
            XCTAssertNil(recent.matchingURL(second, source: .clipboard, now: time.addingTimeInterval(3)))
            XCTAssertNil(recent.matchingURL(first, source: .file, now: time.addingTimeInterval(6)))
            XCTAssertNil(recent.matchingURL(second, source: .file, now: time.addingTimeInterval(8)))
            XCTAssertFalse(recent.contains(second, now: time.addingTimeInterval(8)))

            recent.record(first, at: time.addingTimeInterval(9))
            XCTAssertTrue(recent.contains(first, now: time.addingTimeInterval(9)))
            XCTAssertNil(recent.matchingURL(first, source: .file, now: time.addingTimeInterval(9)), "A content-only cache entry must not invent a reusable file URL")
        }
    }

    @MainActor
    func testRecapturingLiveImageUpdatesLatestWithoutMovingBrowsedCardsAndNeverReusesDroppedCard() async throws {
        try await withEnvironment { _, folder in
            let line = Line(persist: false)
            line.pageSize = 2
            var ids: [UUID] = []
            for index in 0..<4 {
                let url = folder.appendingPathComponent("recapture-\(index).png")
                try png(64 + index).write(to: url, options: .atomic)
                ids.append(try XCTUnwrap(line.hang(url, quietly: true)))
            }
            let initialOrder = line.liveItems.map(\.id)
            XCTAssertTrue(line.recapture(ids[0]))
            XCTAssertEqual(line.liveCount, 4)
            XCTAssertEqual(line.liveItems.map(\.id), initialOrder, "Reusing a card must not create or reorder images")
            XCTAssertEqual(line.latestCaptureID, ids[0])
            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertTrue(line.visibleItems.contains { $0.id == ids[0] })

            line.showPage(0)
            let browsedIDs = line.visibleItems.map(\.id)
            XCTAssertTrue(line.recapture(ids[0]))
            XCTAssertTrue(line.isBrowsing)
            XCTAssertEqual(line.latestCaptureID, ids[0])
            XCTAssertEqual(line.pageIndex, 0)
            XCTAssertEqual(line.visibleItems.map(\.id), browsedIDs)
            XCTAssertEqual(line.pendingCount, 1)
            XCTAssertTrue(line.recapture(ids[0]))
            XCTAssertEqual(line.pendingCount, 1, "Repeating the same copied image counts one pending card")
            line.showLatest()
            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertEqual(line.pendingCount, 0)
            XCTAssertTrue(line.visibleItems.contains { $0.id == ids[0] })

            line.drop(ids[0], quietly: true)
            let countAfterDrop = line.liveCount
            XCTAssertFalse(line.recapture(ids[0]), "A falling card is already taken down and must not be reused")
            XCTAssertEqual(line.liveCount, countAfterDrop)
            XCTAssertFalse(line.liveItems.contains { $0.id == ids[0] })
            XCTAssertEqual(line.pendingCount, 0)
        }
    }

    @MainActor
    func testCopiedImageOnFullLineDoesNotDisplaceTheBrowsedPage() async throws {
        try await withEnvironment { pasteboard, folder in
            let line = Line(persist: false)
            line.pageSize = 7
            for index in 0..<20 {
                let url = folder.appendingPathComponent("existing-\(index).png")
                try png(index + 20).write(to: url, options: .atomic)
                XCTAssertNotNil(line.hang(url, quietly: true))
            }
            line.showPage(1)
            let originalIDs = line.visibleItems.map(\.id)
            var captures: [URL] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard, captureFolder: folder, captureDelay: 0.03,
                                           onCapture: { url, _ in
                                               captures.append(url)
                                               line.hang(url, quietly: true)
                                           }, onText: { _ in XCTFail("An image must not create a URL note") }, recentlyHungFromFile: { _ in false })
            watcher.textEnabled = true
            defer { watcher.stop() }
            copyImage(try png(99), to: pasteboard, withWebMetadata: true)
            watcher.poll()
            try await waitForCapture()

            XCTAssertEqual(captures.count, 1)
            XCTAssertEqual(line.liveCount, 20)
            XCTAssertTrue(line.isBrowsing)
            XCTAssertEqual(line.pageIndex, 1)
            XCTAssertEqual(line.visibleItems.map(\.id), originalIDs)
            XCTAssertEqual(line.pendingCount, 1)
            line.showLatest()
            XCTAssertEqual(line.pageIndex, 0)
            XCTAssertEqual(line.pendingCount, 0)
            XCTAssertEqual(line.visibleItems.first?.url, captures.first)
            XCTAssertEqual(line.visibleItems.first?.id, line.latestCaptureID)
        }
    }
}
