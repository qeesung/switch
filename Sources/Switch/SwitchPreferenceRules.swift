import Foundation

/// Validation and one-time migration rules for picker sizing preferences.
/// Kept independent of UserDefaults so corrupt or legacy values are easy to test.
enum SwitchPreferenceRules {
    static let defaultMaxListRows = 8
    static let maxListRowsRange = 4...20

    static let defaultListWidth = 520.0
    static let listWidthRange = 420.0...1000.0

    static func clampedMaxListRows(_ value: Int) -> Int {
        min(max(value, maxListRowsRange.lowerBound), maxListRowsRange.upperBound)
    }

    static func clampedListWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultListWidth }
        return min(max(value, listWidthRange.lowerBound), listWidthRange.upperBound)
    }

    /// There was no list-width key before this preference was introduced. The old
    /// picker implicitly used `520 * thumbnailHeight / 130`, so preserve that visual
    /// width the first time the new key is absent. Once present, the dedicated value
    /// always wins and is merely clamped.
    static func resolvedListWidth(
        storedListWidth: Double?,
        legacyThumbnailHeight: Double?
    ) -> Double {
        if let storedListWidth {
            return clampedListWidth(storedListWidth)
        }

        let thumbnailHeight = legacyThumbnailHeight ?? 130.0
        return clampedListWidth(defaultListWidth * thumbnailHeight / 130.0)
    }
}
