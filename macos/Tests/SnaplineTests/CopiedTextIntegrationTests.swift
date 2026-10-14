import AppKit
import XCTest
@testable import Snapline

final class CopiedTextIntegrationTests: XCTestCase {
    func testClipboardToEditableNotePreservesFullTextAndDeduplicatesLiveCards() async throws {
        try await MainActor.run {
            // Notes stores metadata in Settings.current. Preserve it in memory,
            // forbid disk writes, and use temporary files for every generated image.
            let originalSettings = Settings.current
            let originalReadOnly = Settings.readOnly
            Settings.readOnly = true
            Settings.current = Settings()
            defer {
                Settings.current = originalSettings
                Settings.readOnly = originalReadOnly
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineClipboardTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            try withTestPasteboard { pasteboard in
                let line = Line(persist: false)
                let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                               onCapture: { _, _ in XCTFail("A copied text note must use the note pipeline") },
                                               onText: { line.hangCopiedText($0, in: folder) },
                                               recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                defer { watcher.stop() }

                let text = "办公便签 🧺\n今天先完成：\n  1. 整理会议纪要\n  2. 准备项目材料\n\n" + String(repeating: "中文原文与 emoji 👩🏽‍💻 不应被截断。\n", count: 350)
                XCTAssertGreaterThan(text.count, 4000)
                copyTestText(text, to: pasteboard)
                watcher.poll()
                let first = try XCTUnwrap(line.items.first)
                XCTAssertEqual(line.liveCount, 1)
                XCTAssertEqual(first.url.deletingLastPathComponent(), folder)
                XCTAssertTrue(first.isNote)
                XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
                XCTAssertNotNil(NSImage(contentsOf: first.url))
                XCTAssertEqual(pixelSize(first.url), CGSize(width: 720, height: 540))
                XCTAssertEqual(Notes.get(first.url)?.text, text, "Only the visual preview is shortened; editable text must remain complete")

                // An optional preview is useful for offline visual verification.
                // Default test runs leave no output outside their temporary directory.
                if let previewPath = ProcessInfo.processInfo.environment["SNAPLINE_TEST_PREVIEW_PATH"], !previewPath.isEmpty {
                    let preview = URL(fileURLWithPath: previewPath)
                    try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(contentsOf: first.url).write(to: preview, options: .atomic)
                }

                copyTestText(text, to: pasteboard)
                watcher.poll()
                XCTAssertEqual(line.liveCount, 1, "Repeated copies should reuse a matching live note")
                XCTAssertEqual(line.items.first?.id, first.id)

                line.drop(first.id, quietly: true)
                XCTAssertEqual(line.liveCount, 0)
                copyTestText(text, to: pasteboard)
                watcher.poll()
                let second = try XCTUnwrap(line.items.first(where: { !$0.falling }))
                XCTAssertNotEqual(second.id, first.id)
                XCTAssertNotEqual(second.url, first.url)
                XCTAssertEqual(line.liveCount, 1, "After taking a note down, the same text may hang again")

                let editedText = "编辑后的文字 ✅\n完整保留换行"
                Notes.update(second.url, text: editedText, color: "green")
                line.reloadThumbnail(for: second.url)
                XCTAssertEqual(Notes.get(second.url)?.text, editedText)
                XCTAssertEqual(Notes.get(second.url)?.color, "green")
                XCTAssertNotNil(NSImage(contentsOf: second.url))
            }
        }
    }
}
