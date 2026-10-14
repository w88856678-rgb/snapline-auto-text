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
                    if let line = child.value as? Line {
                        values["lineRevealed"] = line.revealed
                        values["liveCount"] = line.liveCount
                        values["pageIndex"] = line.pageIndex
                        values["pageSize"] = line.pageSize
                        values["pageCount"] = line.pageCount
                        values["visibleCount"] = line.visibleItems.count
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
