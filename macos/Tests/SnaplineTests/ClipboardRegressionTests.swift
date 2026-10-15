import AppKit
import XCTest
@testable import Snapline

final class ClipboardRegressionTests: XCTestCase {
    @MainActor
    private func copyImage(to pasteboard: NSPasteboard) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                   pixelsWide: 16, pixelsHigh: 12,
                                                   bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(png, forType: .png))
    }

    @MainActor
    func testPureImageStillReachesOriginalImagePipeline() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var examined: [CGSize] = []
        let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                       onCapture: { _, _ in XCTFail("The image interception must prevent writing into the real Inbox") },
                                       onText: { _ in XCTFail("A pure image must not produce a text note") },
                                       recentlyHungFromFile: { image in
                                           examined.append(image.size)
                                           // Stop after image validation, before Inbox.newCapturePath().
                                           return true
                                       })
        watcher.textEnabled = true
        defer { watcher.stop() }
        try copyImage(to: pasteboard)
        watcher.poll()
        try await Task.sleep(nanoseconds: 1_450_000_000)
        XCTAssertEqual(examined, [CGSize(width: 16, height: 12)])
        watcher.poll()
        XCTAssertEqual(examined.count, 1, "An unchanged pasteboard must not schedule another image capture")
    }

    @MainActor
    func testDisablingThenReenablingImageCaptureCancelsPendingImage() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var examined = 0
        let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                       onCapture: { _, _ in XCTFail("Never write test images into the real Inbox") },
                                       onText: { _ in XCTFail("A pure image must not produce text") },
                                       recentlyHungFromFile: { _ in examined += 1; return true })
        defer { watcher.stop() }
        try copyImage(to: pasteboard)
        watcher.poll()
        watcher.enabled = false
        watcher.enabled = true
        try await Task.sleep(nanoseconds: 1_450_000_000)
        XCTAssertEqual(examined, 0, "The queued image must be canceled even if image capture is reenabled before its delay expires")
        try copyImage(to: pasteboard)
        watcher.poll()
        try await Task.sleep(nanoseconds: 1_450_000_000)
        XCTAssertEqual(examined, 1, "A new image copied after reenabling must still enter the pipeline")
    }

    @MainActor
    func testStopCancelsPendingImageCapture() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var examined = 0
        let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                       onCapture: { _, _ in XCTFail("Never write test images into the real Inbox") },
                                       onText: { _ in XCTFail("A pure image must not produce text") },
                                       recentlyHungFromFile: { _ in examined += 1; return true })
        defer { watcher.stop() }
        try copyImage(to: pasteboard)
        watcher.poll()
        watcher.stop()
        try await Task.sleep(nanoseconds: 1_450_000_000)
        XCTAssertEqual(examined, 0)
    }

    @MainActor
    private func withTemporaryNotes(_ body: (Line, URL) throws -> Void) throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        defer {
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineCapacityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let line = Line(persist: false)
        line.maxItems = 2
        try body(line, folder)
    }

    @MainActor
    func testCopyingTextOntoFullLineKeepsLatestNoteAndDropsOldest() async throws {
        try withTemporaryNotes { line, folder in
            try withTestPasteboard { pasteboard in
                let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                               onCapture: { _, _ in XCTFail("Text must use the note pipeline") },
                                               onText: { line.hangCopiedText($0, in: folder) },
                                               recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                defer { watcher.stop() }
                for text in ["旧便签1", "旧便签2", "新复制的文字"] {
                    copyTestText(text, to: pasteboard)
                    watcher.poll()
                }
                XCTAssertEqual(line.liveCount, 2)
                XCTAssertEqual(line.items.filter { !$0.falling }.compactMap { Notes.get($0.url)?.text }, ["旧便签2", "新复制的文字"])
                let oldest = try XCTUnwrap(line.items.first { Notes.get($0.url)?.text == "旧便签1" })
                XCTAssertTrue(oldest.falling)
            }
        }
    }

    @MainActor
    func testCopyingTextOntoAllPinnedLineKeepsNewNoteVisible() async throws {
        try withTemporaryNotes { line, folder in
            let first = try XCTUnwrap(line.hangCopiedText("固定1", in: folder))
            let second = try XCTUnwrap(line.hangCopiedText("固定2", in: folder))
            line.togglePin(first)
            line.togglePin(second)
            try withTestPasteboard { pasteboard in
                let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                               onCapture: { _, _ in XCTFail("Text must use the note pipeline") },
                                               onText: { line.hangCopiedText($0, in: folder) },
                                               recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                defer { watcher.stop() }
                copyTestText("固定满架后新复制的文字", to: pasteboard)
                watcher.poll()
                let note = try XCTUnwrap(line.items.first { Notes.get($0.url)?.text == "固定满架后新复制的文字" })
                XCTAssertFalse(note.falling, "New copied text must remain visible when every existing card is pinned")
                XCTAssertEqual(line.liveCount, 3, "A full pinned line may temporarily keep its newest unpinned note")
                XCTAssertTrue(line.item(first)?.pinned == true)
                XCTAssertTrue(line.item(second)?.pinned == true)
                copyTestText("固定满架后下一次复制", to: pasteboard)
                watcher.poll()
                let next = try XCTUnwrap(line.items.first { Notes.get($0.url)?.text == "固定满架后下一次复制" })
                XCTAssertFalse(next.falling)
                XCTAssertTrue(line.item(note.id)?.falling == true, "The next copy must replace the prior extra unpinned note")
                XCTAssertEqual(line.liveCount, 3)
            }
        }
    }
}
