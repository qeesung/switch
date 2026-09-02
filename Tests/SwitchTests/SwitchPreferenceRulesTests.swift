import XCTest

final class SwitchPreferenceRulesTests: XCTestCase {
    func testPickerSizeKeepsValidStoredChoice() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedPickerSizeRawValue(
                storedRawValue: "compact",
                legacyThumbnailHeight: nil,
                legacyAppIconSize: nil
            ),
            "compact"
        )
    }

    func testPickerSizeDefaultsToLargeWithoutExplicitLegacySizing() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedPickerSizeRawValue(
                storedRawValue: nil,
                legacyThumbnailHeight: nil,
                legacyAppIconSize: nil
            ),
            "large"
        )
    }

    func testPickerSizeMigratesExplicitLegacySizingAtStandardScale() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedPickerSizeRawValue(
                storedRawValue: nil,
                legacyThumbnailHeight: 180,
                legacyAppIconSize: nil
            ),
            "standard"
        )
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedPickerSizeRawValue(
                storedRawValue: "invalid",
                legacyThumbnailHeight: nil,
                legacyAppIconSize: 40
            ),
            "standard"
        )
    }

    func testLegacyThumbnailValuesRetainTheirExactGridScaleAtMigration() {
        for thumbnailHeight in [80.0, 130.0, 180.0, 300.0] {
            XCTAssertEqual(
                SwitchPreferenceRules.gridScale(
                    pickerScale: SwitchPreferenceRules.standardPickerScale,
                    thumbnailHeight: thumbnailHeight
                ),
                thumbnailHeight / 130,
                accuracy: 0.000_001
            )
        }
    }

    func testGridScaleCombinesVisualPresetAndAdvancedThumbnailSize() {
        XCTAssertEqual(
            SwitchPreferenceRules.gridScale(pickerScale: 1.2, thumbnailHeight: 130),
            1.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SwitchPreferenceRules.gridScale(pickerScale: 1.2, thumbnailHeight: 180),
            1.2 * 180 / 130,
            accuracy: 0.000_001
        )
    }

    func testGridScaleRejectsInvalidPersistedNumbers() {
        XCTAssertEqual(
            SwitchPreferenceRules.gridScale(pickerScale: .nan, thumbnailHeight: .infinity),
            1,
            accuracy: 0.000_001
        )
    }

    func testMaxListRowsClampsToSupportedRange() {
        XCTAssertEqual(SwitchPreferenceRules.clampedMaxListRows(-1), 4)
        XCTAssertEqual(SwitchPreferenceRules.clampedMaxListRows(12), 12)
        XCTAssertEqual(SwitchPreferenceRules.clampedMaxListRows(99), 20)
    }

    func testListWidthClampsToSupportedRange() {
        XCTAssertEqual(SwitchPreferenceRules.clampedListWidth(100), 420)
        XCTAssertEqual(SwitchPreferenceRules.clampedListWidth(760), 760)
        XCTAssertEqual(SwitchPreferenceRules.clampedListWidth(2_000), 1_000)
    }

    func testNonFiniteListWidthsFallBackToDefault() {
        XCTAssertEqual(SwitchPreferenceRules.clampedListWidth(.nan), 520)
        XCTAssertEqual(SwitchPreferenceRules.clampedListWidth(.infinity), 520)
        XCTAssertEqual(SwitchPreferenceRules.clampedListWidth(-.infinity), 520)
    }

    func testDefaultLegacyThumbnailHeightMigratesToDefaultWidth() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: nil,
                legacyThumbnailHeight: 130
            ),
            520
        )
    }

    func testSmallLegacyThumbnailHeightMigratesToWidthFloor() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: nil,
                legacyThumbnailHeight: 80
            ),
            420
        )
    }

    func testLargeLegacyThumbnailHeightMigratesToWidthCeiling() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: nil,
                legacyThumbnailHeight: 300
            ),
            1_000
        )
    }

    func testExistingListWidthTakesPriorityOverLegacyThumbnailHeight() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: 730,
                legacyThumbnailHeight: 300
            ),
            730
        )
    }

    func testExistingOutOfRangeListWidthsAreClamped() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: 200,
                legacyThumbnailHeight: 130
            ),
            420
        )
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: 1_500,
                legacyThumbnailHeight: 130
            ),
            1_000
        )
    }

    func testMissingAndInvalidLegacyValueUsesDefaultWidth() {
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: nil,
                legacyThumbnailHeight: .nan
            ),
            520
        )
        XCTAssertEqual(
            SwitchPreferenceRules.resolvedListWidth(
                storedListWidth: nil,
                legacyThumbnailHeight: nil
            ),
            520
        )
    }
}
