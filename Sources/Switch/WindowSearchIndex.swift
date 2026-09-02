import CoreGraphics
import Foundation

struct WindowSearchIndex {
    struct TextMatch: Equatable {
        enum Kind: Equatable {
            case direct
            case phonetic
        }

        let kind: Kind
        /// Grapheme-cluster offsets in the original app name or window title.
        let characterOffsets: IndexSet
    }

    struct Result: Identifiable, Equatable {
        let window: WindowInfo
        let appNameMatch: TextMatch?
        let titleMatch: TextMatch?

        var id: CGWindowID { window.id }
    }

    /// A normalized string plus source-grapheme offsets for every normalized
    /// character. The mapping lets `feishu` highlight `飞书`, rather than a
    /// transliterated string that is never shown to the user.
    private struct SearchProjection {
        let text: String
        let sourceOffsetSets: [IndexSet]

        init(direct source: String) {
            let sourceCharacters = Array(source)
            var projectedCharacters: [Character] = []
            var mappings: [IndexSet] = []
            for (sourceOffset, character) in sourceCharacters.enumerated() {
                let normalizedCharacters = Array(String(character).lowercased())
                projectedCharacters.append(contentsOf: normalizedCharacters)
                mappings.append(contentsOf: repeatElement(
                    IndexSet(integer: sourceOffset),
                    count: normalizedCharacters.count
                ))
            }

            let expected = source.lowercased()
            if String(projectedCharacters) == expected {
                text = expected
                sourceOffsetSets = mappings
            } else {
                text = expected
                let allSourceOffsets = IndexSet(integersIn: 0..<sourceCharacters.count)
                sourceOffsetSets = Array(repeating: allSourceOffsets, count: expected.count)
            }
        }

        /// Transliterate each contiguous Han phrase once. Foundation keeps its
        /// tone-free syllables separated, so the common path maps each syllable
        /// directly to one source grapheme in O(n), including contextual readings
        /// such as `重庆` -> `chong qing`.
        init(phonetic source: String) {
            let sourceCharacters = Array(source)
            var projectedCharacters: [Character] = []
            var mappings: [IndexSet] = []
            var runStart = 0

            while runStart < sourceCharacters.count {
                let ideographic = WindowSearchIndex.isIdeographic(sourceCharacters[runStart])
                var runEnd = runStart + 1
                while runEnd < sourceCharacters.count,
                      WindowSearchIndex.isIdeographic(sourceCharacters[runEnd]) == ideographic {
                    runEnd += 1
                }

                let run = String(sourceCharacters[runStart..<runEnd])
                let latin = WindowSearchIndex.toneFreeLatinText(run)
                let compactCharacters = WindowSearchIndex.compactAlphanumerics(latin)

                if ideographic {
                    let syllables = WindowSearchIndex.alphanumericTokens(latin)
                    if syllables.count == runEnd - runStart {
                        for (syllableOffset, syllable) in syllables.enumerated() {
                            let characters = Array(syllable)
                            projectedCharacters.append(contentsOf: characters)
                            mappings.append(contentsOf: repeatElement(
                                IndexSet(integer: runStart + syllableOffset),
                                count: characters.count
                            ))
                        }
                    } else {
                        Self.appendConservativeRun(
                            characters: compactCharacters,
                            sourceRange: runStart..<runEnd,
                            projectedCharacters: &projectedCharacters,
                            mappings: &mappings
                        )
                    }
                } else {
                    let alphanumericSourceOffsets = sourceCharacters[runStart..<runEnd]
                        .enumerated()
                        .compactMap { relativeOffset, character in
                            character.unicodeScalars.contains(where: {
                                CharacterSet.alphanumerics.contains($0)
                            }) ? runStart + relativeOffset : nil
                        }
                    if alphanumericSourceOffsets.count == compactCharacters.count {
                        projectedCharacters.append(contentsOf: compactCharacters)
                        mappings.append(contentsOf: alphanumericSourceOffsets.map {
                            IndexSet(integer: $0)
                        })
                    } else {
                        Self.appendConservativeRun(
                            characters: compactCharacters,
                            sourceRange: runStart..<runEnd,
                            projectedCharacters: &projectedCharacters,
                            mappings: &mappings
                        )
                    }
                }
                runStart = runEnd
            }

            let expected = WindowSearchIndex.phoneticText(source)
            if String(projectedCharacters) == expected {
                text = expected
                sourceOffsetSets = mappings
            } else {
                // If a script does not expose one token per grapheme, retain the
                // exact pre-existing filter projection and highlight its source
                // conservatively rather than showing a match with no highlight.
                text = expected
                let allSourceOffsets = IndexSet(integersIn: 0..<sourceCharacters.count)
                sourceOffsetSets = Array(repeating: allSourceOffsets, count: expected.count)
            }
        }

        private static func appendConservativeRun(
            characters: [Character],
            sourceRange: Range<Int>,
            projectedCharacters: inout [Character],
            mappings: inout [IndexSet]
        ) {
            projectedCharacters.append(contentsOf: characters)
            mappings.append(contentsOf: repeatElement(
                IndexSet(integersIn: sourceRange),
                count: characters.count
            ))
        }
    }

    /// Search projections depend only on a source string, so identical app names
    /// across many windows share one transliteration. This also avoids coupling
    /// the cache to CGWindowID's real/synthetic/Space-representative namespace.
    private struct IndexedText {
        let direct: SearchProjection
        let phonetic: SearchProjection?

        init(_ value: String) {
            direct = SearchProjection(direct: value)
            phonetic = WindowSearchIndex.containsIdeographicText(value)
                ? SearchProjection(phonetic: value)
                : nil
        }
    }

    private enum MatchKind: Int {
        case phonetic
        case direct
    }

    private struct ProjectionMatch {
        let score: Int
        let sourceOffsets: IndexSet
    }

    private struct FuzzyMatch {
        let score: Int
        let targetOffsets: [Int]
    }

    private struct RankedResult {
        let result: Result
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
        results(windows, query: query).map(\.window)
    }

    func results(_ windows: [WindowInfo], query: String) -> [Result] {
        let directPattern = query.lowercased()
        guard !directPattern.isEmpty else {
            return windows.map { Result(window: $0, appNameMatch: nil, titleMatch: nil) }
        }
        // The pre-pinyin filter treats spaces, periods, and hyphens as literal
        // query characters. Restrict phonetic fallback to the unambiguous
        // `feishu` shape so adding transliteration does not broaden those old
        // queries into `foobar`-style matches.
        let phoneticPattern = Self.isPlainPinyinQuery(query)
            ? Self.phoneticText(query)
            : ""

        let matches: [RankedResult] = windows.enumerated().compactMap { originalIndex, window in
            let app = entries[window.appName] ?? IndexedText(window.appName)
            let title = entries[window.title] ?? IndexedText(window.title)
            let directApp = Self.match(pattern: directPattern, projection: app.direct)
            let directTitle = Self.match(pattern: directPattern, projection: title.direct)

            if directApp != nil || directTitle != nil {
                let appMatch = Self.textMatch(
                    direct: directApp,
                    phoneticPattern: phoneticPattern,
                    phonetic: app.phonetic
                )
                let titleMatch = Self.textMatch(
                    direct: directTitle,
                    phoneticPattern: phoneticPattern,
                    phonetic: title.phonetic
                )
                return RankedResult(
                    result: Result(
                        window: window,
                        appNameMatch: appMatch,
                        titleMatch: titleMatch
                    ),
                    kind: .direct,
                    score: max(directApp?.score ?? Int.min, directTitle?.score ?? Int.min),
                    originalIndex: originalIndex
                )
            }

            guard !phoneticPattern.isEmpty else { return nil }
            let phoneticApp = app.phonetic.flatMap {
                Self.match(pattern: phoneticPattern, projection: $0)
            }
            let phoneticTitle = title.phonetic.flatMap {
                Self.match(pattern: phoneticPattern, projection: $0)
            }
            guard phoneticApp != nil || phoneticTitle != nil else { return nil }
            return RankedResult(
                result: Result(
                    window: window,
                    appNameMatch: Self.textMatch(kind: .phonetic, match: phoneticApp),
                    titleMatch: Self.textMatch(kind: .phonetic, match: phoneticTitle)
                ),
                kind: .phonetic,
                score: max(phoneticApp?.score ?? Int.min, phoneticTitle?.score ?? Int.min),
                originalIndex: originalIndex
            )
        }

        return matches.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue > rhs.kind.rawValue }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.originalIndex < rhs.originalIndex
        }.map(\.result)
    }

    private static func textMatch(
        direct: ProjectionMatch?,
        phoneticPattern: String,
        phonetic: SearchProjection?
    ) -> TextMatch? {
        if let direct { return textMatch(kind: .direct, match: direct) }
        guard !phoneticPattern.isEmpty, let phonetic else { return nil }
        return textMatch(
            kind: .phonetic,
            match: match(pattern: phoneticPattern, projection: phonetic)
        )
    }

    private static func textMatch(kind: TextMatch.Kind, match: ProjectionMatch?) -> TextMatch? {
        guard let match else { return nil }
        return TextMatch(kind: kind, characterOffsets: match.sourceOffsets)
    }

    private static func match(
        pattern: String,
        projection: SearchProjection
    ) -> ProjectionMatch? {
        guard let match = fuzzyMatch(pattern: pattern, target: projection.text) else { return nil }
        var sourceOffsets = IndexSet()
        for targetOffset in match.targetOffsets {
            sourceOffsets.formUnion(projection.sourceOffsetSets[targetOffset])
        }
        return ProjectionMatch(
            score: match.score,
            sourceOffsets: sourceOffsets
        )
    }

    private static func isPlainPinyinQuery(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
    }

    private static func containsIdeographicText(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    private static func isIdeographic(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    private static func toneFreeLatinText(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let toneFree = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return toneFree.lowercased()
    }

    private static func compactAlphanumerics(_ value: String) -> [Character] {
        Array(String(value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    private static func alphanumericTokens(_ value: String) -> [String] {
        value.split(whereSeparator: { character in
            !character.unicodeScalars.contains(where: {
                CharacterSet.alphanumerics.contains($0)
            })
        }).map { token in
            String(token.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            })
        }.filter { !$0.isEmpty }
    }

    /// Produces compact, lowercase, tone-free Latin text. Compacting whitespace and
    /// punctuation lets the common unspaced query `feishu` match Foundation's `fei shu`.
    static func phoneticText(_ value: String) -> String {
        String(compactAlphanumerics(toneFreeLatinText(value)))
    }

    static func fuzzyScore(pattern: String, target: String) -> Int? {
        fuzzyMatch(pattern: pattern, target: target)?.score
    }

    private static func fuzzyMatch(pattern: String, target: String) -> FuzzyMatch? {
        let patternCharacters = Array(pattern)
        let targetCharacters = Array(target)
        guard !patternCharacters.isEmpty, patternCharacters.count <= targetCharacters.count else {
            return nil
        }

        // Keep the best match ending at each target character. The old greedy
        // walk locked the first possible character forever, so `dgit` in
        // `...design... — dgit` highlighted the `d` in `design` plus the final
        // `git`. Considering all viable endings lets the existing adjacency and
        // word-boundary bonuses select the contiguous occurrence instead.
        var states = Array<FuzzyMatch?>(repeating: nil, count: targetCharacters.count)
        for targetIndex in targetCharacters.indices
            where targetCharacters[targetIndex] == patternCharacters[0] {
            states[targetIndex] = FuzzyMatch(
                score: characterScore(at: targetIndex, in: targetCharacters)
                    + (targetIndex == 0 ? 5 : 0),
                targetOffsets: [targetIndex]
            )
        }

        for patternIndex in patternCharacters.indices.dropFirst() {
            var next = Array<FuzzyMatch?>(repeating: nil, count: targetCharacters.count)
            var bestNonAdjacent: FuzzyMatch?

            for targetIndex in targetCharacters.indices {
                if targetIndex >= 2, let candidate = states[targetIndex - 2],
                   isBetterPrefix(candidate, than: bestNonAdjacent) {
                    bestNonAdjacent = candidate
                }
                guard targetCharacters[targetIndex] == patternCharacters[patternIndex] else {
                    continue
                }

                let baseScore = characterScore(at: targetIndex, in: targetCharacters)
                if targetIndex > 0, let adjacent = states[targetIndex - 1] {
                    next[targetIndex] = extending(
                        adjacent,
                        with: targetIndex,
                        addedScore: baseScore + 5
                    )
                }
                if let bestNonAdjacent {
                    let candidate = extending(
                        bestNonAdjacent,
                        with: targetIndex,
                        addedScore: baseScore
                    )
                    if isBetterEnding(candidate, than: next[targetIndex]) {
                        next[targetIndex] = candidate
                    }
                }
            }
            states = next
        }

        return states.compactMap { $0 }.reduce(nil as FuzzyMatch?) { best, candidate in
            isBetterCompleteMatch(candidate, than: best) ? candidate : best
        }
    }

    private static func characterScore(at index: Int, in target: [Character]) -> Int {
        1 + ((index == 0 || !target[index - 1].isLetter) ? 3 : 0)
    }

    private static func extending(
        _ match: FuzzyMatch,
        with targetOffset: Int,
        addedScore: Int
    ) -> FuzzyMatch {
        FuzzyMatch(
            score: match.score + addedScore,
            targetOffsets: match.targetOffsets + [targetOffset]
        )
    }

    /// Prefixes compete for the same future end offset, so a later start yields
    /// the tighter final span when scores are equal.
    private static func isBetterPrefix(_ candidate: FuzzyMatch, than current: FuzzyMatch?) -> Bool {
        guard let current else { return true }
        if candidate.score != current.score { return candidate.score > current.score }
        return candidate.targetOffsets[0] > current.targetOffsets[0]
    }

    /// Matches ending at the same target character prefer the tighter span.
    private static func isBetterEnding(_ candidate: FuzzyMatch, than current: FuzzyMatch?) -> Bool {
        guard let current else { return true }
        if candidate.score != current.score { return candidate.score > current.score }
        return candidate.targetOffsets[0] > current.targetOffsets[0]
    }

    /// Across different endings, prefer score, then compactness, then the first
    /// occurrence so equal matches remain visually stable.
    private static func isBetterCompleteMatch(
        _ candidate: FuzzyMatch,
        than current: FuzzyMatch?
    ) -> Bool {
        guard let current else { return true }
        if candidate.score != current.score { return candidate.score > current.score }
        let candidateSpan = candidate.targetOffsets.last! - candidate.targetOffsets[0]
        let currentSpan = current.targetOffsets.last! - current.targetOffsets[0]
        if candidateSpan != currentSpan { return candidateSpan < currentSpan }
        return candidate.targetOffsets[0] < current.targetOffsets[0]
    }
}
