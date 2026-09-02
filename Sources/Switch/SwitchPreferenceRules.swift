import Foundation

/// Validation and one-time migration rules for picker sizing preferences.
/// Kept independent of UserDefaults so corrupt or legacy values are easy to test.
enum SwitchPreferenceRules {
    static let compactPickerScale = 0.9
    static let standardPickerScale = 1.0
    static let largePickerScale = 1.2
    static let defaultPickerSizeRawValue = "large"
    static let legacyDefaultThumbnailHeight = 130.0

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

    /// Preserve an explicitly customized legacy picker at its previous scale. An
    /// uncustomized installation adopts the new, more legible large default.
    static func resolvedPickerSizeRawValue(
        storedRawValue: String?,
        legacyThumbnailHeight: Double?,
        legacyAppIconSize: Double?
    ) -> String {
        if let storedRawValue,
           ["compact", "standard", "large"].contains(storedRawValue) {
            return storedRawValue
        }
        if legacyThumbnailHeight != nil || legacyAppIconSize != nil {
            return "standard"
        }
        return defaultPickerSizeRawValue
    }

    /// The legacy thumbnail slider also controlled the grid frame. Keep that
    /// fine-grained multiplier underneath the new three visual presets so an
    /// explicitly customized installation retains its effective dimensions.
    static func gridScale(pickerScale: Double, thumbnailHeight: Double) -> Double {
        let safePickerScale = pickerScale.isFinite && pickerScale > 0
            ? pickerScale
            : standardPickerScale
        let safeThumbnailHeight = thumbnailHeight.isFinite && thumbnailHeight > 0
            ? thumbnailHeight
            : legacyDefaultThumbnailHeight
        return safePickerScale * safeThumbnailHeight / legacyDefaultThumbnailHeight
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
