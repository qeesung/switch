import CoreGraphics
import Foundation

struct WindowSearchIndex {
    /// Search projections depend only on a source string, so identical app names
    /// across many windows share one transliteration. This also avoids coupling
    /// the cache to CGWindowID's real/synthetic/Space-representative namespace.
    private struct IndexedText {
        let direct: String
        let phonetic: String?

        init(_ value: String) {
            direct = value.lowercased()
            phonetic = WindowSearchIndex.containsIdeographicText(value)
                ? WindowSearchIndex.phoneticText(value)
                : nil
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

    private var entries: [String: IndexedText] = [:]

    var cachedEntryCount: Int { entries.count }

    mutating func synchronize(with windows: [WindowInfo]) {
        let liveTexts = Set(windows.flatMap { [$0.appName, $0.title] })
        entries = entries.filter { liveTexts.contains($0.key) }

        for text in liveTexts where entries[text] == nil {
            entries[text] = IndexedText(text)
        }
    }

    func filtered(_ windows: [WindowInfo], query: String) -> [WindowInfo] {
        let directPattern = query.lowercased()
        guard !directPattern.isEmpty else { return windows }
        // The pre-pinyin filter treats spaces, periods, and hyphens as literal
        // query characters. Restrict phonetic fallback to the unambiguous
        // `feishu` shape so adding transliteration does not broaden those old
        // queries into `foobar`-style matches.
        let phoneticPattern = Self.isPlainPinyinQuery(query)
            ? Self.phoneticText(query)
            : ""

        let matches: [Match] = windows.enumerated().compactMap { originalIndex, window in
            let app = entries[window.appName] ?? IndexedText(window.appName)
            let title = entries[window.title] ?? IndexedText(window.title)
            if let score = Self.bestScore(
                pattern: directPattern,
                targets: [app.direct, title.direct]
            ) {
                return Match(window: window, kind: .direct, score: score, originalIndex: originalIndex)
            }
            guard !phoneticPattern.isEmpty,
                  let score = Self.bestScore(
                    pattern: phoneticPattern,
                    targets: [app.phonetic, title.phonetic].compactMap { $0 }
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

    private static func isPlainPinyinQuery(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
    }

    private static func containsIdeographicText(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.isIdeographic }
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
