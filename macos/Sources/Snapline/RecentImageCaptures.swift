import Foundation

/// Only files actually captured during this run participate in screenshot
/// deduplication. Restored cards and unrelated images with the same size do not.
@MainActor
final class RecentImageCaptures {
    enum Source { case file, clipboard }
    private struct Entry {
        let date: Date
        let url: URL?
        let source: Source
    }
    private var captured: [Data: Entry] = [:]
    private let lifetime: TimeInterval = 5

    func record(_ image: ClipboardImage, url: URL? = nil, source: Source = .file, at date: Date = Date()) {
        prune(at: date)
        captured[image.fingerprint] = Entry(date: date, url: url, source: source)
    }

    func contains(_ image: ClipboardImage, now: Date = Date()) -> Bool {
        prune(at: now)
        return captured[image.fingerprint] != nil
    }

    func matchingURL(_ image: ClipboardImage, source: Source, now: Date = Date()) -> URL? {
        prune(at: now)
        guard let entry = captured[image.fingerprint], entry.source == source else { return nil }
        return entry.url
    }

    private func prune(at date: Date) {
        captured = captured.filter { date.timeIntervalSince($0.value.date) < lifetime }
    }
}
