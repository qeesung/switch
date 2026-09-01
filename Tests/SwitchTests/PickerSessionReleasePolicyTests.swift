import XCTest

final class PickerSessionReleasePolicyTests: XCTestCase {
    func testRegularSessionCommitsWhenArmingModifiersAreReleased() {
        XCTAssertEqual(PickerSessionReleasePolicy.action(isSticky: false), .commit)
    }

    func testStickyQuickReleaseKeepsPickerOpen() {
        XCTAssertEqual(PickerSessionReleasePolicy.action(isSticky: true), .keepOpen)
    }

    func testStickySlowReleaseKeepsPickerOpen() {
        XCTAssertEqual(PickerSessionReleasePolicy.action(isSticky: true), .keepOpen)
    }

    func testRepeatedStickySessionsNeverCommitOnModifierRelease() {
        for _ in 0..<10 {
            XCTAssertEqual(PickerSessionReleasePolicy.action(isSticky: true), .keepOpen)
        }
    }
}
