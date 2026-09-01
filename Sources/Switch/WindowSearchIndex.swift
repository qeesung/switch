import CoreGraphics
import Foundation

struct WindowSearchIndex {
    private struct Entry {
        let appName: String
        let title: String
        let directAppName: String
        let directTitle: String
        let phoneticAppName: String
        let phoneticTitle: String

        init(_ window: WindowInfo) {
            appName = window.appName
            title = window.title
            directAppName = Self.directText(window.appName)
            directTitle = Self.directText(window.title)
            phoneticAppName = Self.phoneticText(window.appName)
            phoneticTitle = Self.phoneticText(window.title)
        }

        func matchesSource(_ window: WindowInfo) -> Bool {
            appName == window.appName && title == window.title
        }

        private static func directText(_ value: String) -> String {
            value.lowercased()
        }

        private static func phoneticText(_ value: String) -> String {
            WindowSearchIndex.phoneticText(value)
        }
    }

    private enum MatchKind: Int {
        case phonetic
        case direct
    }

    private struct Match {
        let window: WindowInfo
        let kind: MatchKind
        let score: Int
        let originalIndex: Int
    }

    private var entries: [CGWindowID: Entry] = [:]

    var cachedEntryCount: Int { entries.count }

    mutating func synchronize(with windows: [WindowInfo]) {
        let liveIDs = Set(windows.map(\.id))
        entries = entries.filter { liveIDs.contains($0.key) }

        for window in windows where entries[window.id]?.matchesSource(window) != true {
            entries[window.id] = Entry(window)
        }
    }

    func filtered(_ windows: [WindowInfo], query: String) -> [WindowInfo] {
        let directPattern = query.lowercased()
        guard !directPattern.isEmpty else { return windows }
        let phoneticPattern = Self.phoneticText(query)

        let matches: [Match] = windows.enumerated().compactMap { originalIndex, window in
            let entry = entries[window.id] ?? Entry(window)
            if let score = Self.bestScore(
                pattern: directPattern,
                targets: [entry.directAppName, entry.directTitle]
            ) {
                return Match(window: window, kind: .direct, score: score, originalIndex: originalIndex)
            }
            guard !phoneticPattern.isEmpty,
                  let score = Self.bestScore(
                    pattern: phoneticPattern,
                    targets: [entry.phoneticAppName, entry.phoneticTitle]
                  ) else { return nil }
            return Match(window: window, kind: .phonetic, score: score, originalIndex: originalIndex)
        }

        return matches.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue > rhs.kind.rawValue }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.originalIndex < rhs.originalIndex
        }.map(\.window)
    }

    private static func bestScore(pattern: String, targets: [String]) -> Int? {
        targets.compactMap { fuzzyScore(pattern: pattern, target: $0) }.max()
    }

    /// Produces compact, lowercase, tone-free Latin text. Compacting whitespace and
    /// punctuation lets the common unspaced query `feishu` match Foundation's `fei shu`.
    static func phoneticText(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let toneFree = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(toneFree.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    static func fuzzyScore(pattern: String, target: String) -> Int? {
        let pat = Array(pattern)
        let tgt = Array(target)
        var score = 0
        var patIdx = 0
        var lastMatch = -1
        for (i, character) in tgt.enumerated() {
            guard patIdx < pat.count else { break }
            if character == pat[patIdx] {
                score += 1
                if lastMatch == i - 1 { score += 5 }
                if i == 0 || !tgt[i - 1].isLetter { score += 3 }
                lastMatch = i
                patIdx += 1
            }
        }
        return patIdx == pat.count ? score : nil
    }
}
