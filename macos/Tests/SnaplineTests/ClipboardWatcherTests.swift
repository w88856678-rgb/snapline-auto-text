import AppKit
import XCTest
@testable import Snapline

final class ClipboardWatcherTests: XCTestCase {
    func testOneClipboardChangeIsCapturedOnlyOnce() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                               onCapture: { _, _ in XCTFail("Text must not create an image capture") },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                copyTestText("一次复制，一张便签 🧺", to: pasteboard)
                watcher.poll()
                watcher.poll()
                watcher.poll()
                XCTAssertEqual(received, ["一次复制，一张便签 🧺"])
                watcher.stop()
            }
        }
    }

    func testAnExplicitSecondCopyOfTheSameTextProducesAnotherNote() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard, onCapture: { _, _ in },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                copyTestText("同一段文字", to: pasteboard)
                watcher.poll()
                copyTestText("同一段文字", to: pasteboard)
                watcher.poll()
                XCTAssertEqual(received, ["同一段文字", "同一段文字"])
                watcher.stop()
            }
        }
    }

    func testEnablingTextDoesNotReplayCopiesMadeWhileDisabled() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard, onCapture: { _, _ in },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                watcher.textEnabled = false
                copyTestText("关闭时复制的旧文字", to: pasteboard)
                watcher.textEnabled = true
                watcher.poll()
                XCTAssertTrue(received.isEmpty)
                copyTestText("开启后复制的新文字", to: pasteboard)
                watcher.poll()
                XCTAssertEqual(received, ["开启后复制的新文字"])
                watcher.stop()
            }
        }
    }

    func testPollingWhileBothFeaturesAreDisabledDiscardsTheChange() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard,
                                               onCapture: { _, _ in XCTFail("Both capture features are disabled") },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = false
                copyTestText("已停用", to: pasteboard)
                watcher.poll()
                watcher.textEnabled = true
                watcher.poll()
                XCTAssertTrue(received.isEmpty)
                watcher.stop()
            }
        }
    }

    func testImageCaptureSwitchDoesNotDisableNewTextCopies() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard, onCapture: { _, _ in },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.textEnabled = true
                copyTestText("开关变化前的文字", to: pasteboard)
                watcher.enabled = false
                watcher.poll()
                XCTAssertTrue(received.isEmpty, "Changing capture settings resets the clipboard baseline")
                copyTestText("只开启文字捕获", to: pasteboard)
                watcher.poll()
                XCTAssertEqual(received, ["只开启文字捕获"])
                watcher.stop()
            }
        }
    }

    func testStartAndRestartDoNotHangPreexistingClipboardText() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard, onCapture: { _, _ in },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                copyTestText("启动之前已存在的文字", to: pasteboard)
                watcher.start()
                watcher.poll()
                XCTAssertTrue(received.isEmpty)
                copyTestText("启动后的文字", to: pasteboard)
                watcher.poll()
                XCTAssertEqual(received, ["启动后的文字"])
                watcher.stop()
                copyTestText("停止期间复制的文字", to: pasteboard)
                watcher.start()
                watcher.poll()
                XCTAssertEqual(received, ["启动后的文字"])
                watcher.stop()
            }
        }
    }

    func testProtectedAndOwnCopiesNeverReachTextCallback() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                var received: [String] = []
                let watcher = ClipboardWatcher(pasteboard: pasteboard, onCapture: { _, _ in },
                                               onText: { received.append($0) }, recentlyHungFromFile: { _ in false })
                watcher.enabled = false
                watcher.textEnabled = true
                for marker in [ClipboardContent.ownCopyType, .init("org.nspasteboard.ConcealedType")] {
                    copyTestText("不可自动捕获", to: pasteboard)
                    XCTAssertTrue(pasteboard.setData(Data(), forType: marker))
                    watcher.poll()
                }
                copyTestText(" \n\t", to: pasteboard)
                watcher.poll()
                XCTAssertTrue(received.isEmpty)
                copyTestText("普通的新复制内容", to: pasteboard)
                watcher.poll()
                XCTAssertEqual(received, ["普通的新复制内容"])
                watcher.stop()
            }
        }
    }
}
