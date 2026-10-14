import AppKit
import XCTest
@testable import Snapline

final class CardTransferTests: XCTestCase {
    @MainActor
    private func withTemporaryNoteMetadata(_ text: String, _ body: (URL) throws -> Void) throws {
        let originalSettings = Settings.current
        let originalReadOnly = Settings.readOnly
        Settings.readOnly = true
        Settings.current = Settings()
        defer {
            Settings.current = originalSettings
            Settings.readOnly = originalReadOnly
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineCardTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let noteURL = folder.appendingPathComponent("测试便签.png")
        Settings.current.notes[noteURL.path] = .init(text: text, color: "yellow")
        try body(noteURL)
    }

    @MainActor
    func testDraggingNoteExportsCompleteTextWithoutImageOrFile() async throws {
        let text = "  中文办公便签 🧺\n\t保留缩进与换行\n\n" + String(repeating: "完整内容 👩🏽‍💻 不应因为便签预览而被截断。\n", count: 350)
        XCTAssertGreaterThan(text.count, 4000)
        try withTemporaryNoteMetadata(text) { noteURL in
            withTestPasteboard { pasteboard in
                pasteboard.clearContents()
                let writer = CardTransfer.dragWriter(for: noteURL)
                // Inspect before writeObjects consumes the writer. The
                // published pasteboard adds the NSStringPboardType alias.
                XCTAssertEqual(Set(writer.writableTypes(for: pasteboard)), Set([.string, ClipboardContent.ownCopyType]))
                XCTAssertTrue(pasteboard.writeObjects([writer]))
                XCTAssertEqual(pasteboard.string(forType: .string), text)
                XCTAssertFalse((pasteboard.types ?? []).contains(.png))
                XCTAssertFalse((pasteboard.types ?? []).contains(.tiff))
                XCTAssertFalse((pasteboard.types ?? []).contains(.fileURL))
                XCTAssertNil(pasteboard.data(forType: .png))
                XCTAssertNil(pasteboard.data(forType: .tiff))
                XCTAssertNil(pasteboard.string(forType: .fileURL))
            }
        }
    }

    @MainActor
    func testTextTransferDoesNotAutomaticallyHangItsOwnWordsAgain() async {
        withTestPasteboard { pasteboard in
            var received: [String] = []
            let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                           onCapture: { _, _ in XCTFail("A text transfer must not create an image") },
                                           onText: { received.append($0) },
                                           recentlyHungFromFile: { _ in false })
            watcher.enabled = false
            watcher.textEnabled = true
            defer { watcher.stop() }
            let text = "拖进聊天框的原文 ✅\n第二行"
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([CardTransfer.textItem(text)]))
            XCTAssertEqual(pasteboard.string(forType: .string), text)
            XCTAssertNotNil(pasteboard.data(forType: ClipboardContent.ownCopyType))
            XCTAssertTrue(ClipboardContent.shouldIgnore(pasteboard))
            watcher.poll()
            XCTAssertTrue(received.isEmpty, "Dragging or copying an existing note must not create a duplicate on the line")
        }
    }

    @MainActor
    func testDraggingRegularPhotoStillExportsItsFileURL() async throws {
        try withTemporaryNoteMetadata("无关的便签元数据") { noteURL in
            withTestPasteboard { pasteboard in
                let photoURL = noteURL.deletingLastPathComponent().appendingPathComponent("普通截图.png")
                XCTAssertNil(Notes.get(photoURL))
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.writeObjects([CardTransfer.dragWriter(for: photoURL)]))
                XCTAssertTrue((pasteboard.types ?? []).contains(.fileURL))
                XCTAssertEqual(pasteboard.string(forType: .fileURL), photoURL.absoluteString)
                XCTAssertNil(pasteboard.data(forType: ClipboardContent.ownCopyType))
            }
        }
    }
}
