#if DEBUG
import AppKit

/// Opt-in diagnostics for an isolated local UI test bundle. No note or clipboard
/// content is logged, and release builds do not include this code.
@MainActor
enum UIDiagnostics {
    static func start(delegate: AppDelegate) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "SnaplineDiagnosticLog") as? String else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak delegate] _ in
            MainActor.assumeIsolated {
                guard let delegate else { return }
                var values: [String: Any] = [:]
                for child in Mirror(reflecting: delegate).children {
                    guard let label = child.label else { continue }
                    if let value = child.value as? Bool { values[label] = value }
                    if let reveal = child.value as? QuietRevealState {
                        values["manuallyOpened"] = reveal.isManual
                        values["newItemCount"] = reveal.unseenIDs.count
                    }
                    if let line = child.value as? Line {
                        values["lineRevealed"] = line.revealed
                        values["liveCount"] = line.liveCount
                        values["pageIndex"] = line.pageIndex
                        values["pageSize"] = line.pageSize
                        values["pageCount"] = line.pageCount
                        values["visibleCount"] = line.visibleItems.count
                        values["visibleIDs"] = line.visibleItems.map { $0.id.uuidString }
                        values["isBrowsing"] = line.isBrowsing
                        values["pendingCount"] = line.pendingCount
                        values["latestCaptureID"] = line.latestCaptureID?.uuidString
                        values["hitRectCount"] = line.hitRects.count
                        values["unused"] = line.hasUnused
                    }
                }
                if let panel = NSApp.windows.first(where: { $0 is LinePanel }) {
                    values["windowVisible"] = panel.isVisible
                    values["windowFrame"] = NSStringFromRect(panel.frame)
                    values["ignoresMouseEvents"] = panel.ignoresMouseEvents
                    if let host = panel.contentView {
                        values["hostFrame"] = NSStringFromRect(host.frame)
                        values["hostBounds"] = NSStringFromRect(host.bounds)
                        values["visibleRect"] = NSStringFromRect(host.visibleRect)
                    }
                }
                values["onboardingVisible"] = OnboardingWindow.isVisible
                values["shortcutRegistered"] = ShortcutController.shared.registered
                values["shortcutLabel"] = ShortcutController.shared.shortcut.label
                values["hoverEnabled"] = Settings.current.hoverRevealEnabled
                values["modal"] = NSApp.modalWindow != nil
                values["stayDown"] = Settings.current.stayDownWhileUnused
                if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif
