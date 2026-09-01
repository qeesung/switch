import XCTest

final class PickerArmTransitionPolicyTests: XCTestCase {
    func testFirstTriggerArms() {
        XCTAssertEqual(transition(nil, next: identity(.allWindows)), .arm)
    }

    func testSameSemanticPickerAdvances() {
        let all = identity(.allWindows, sticky: true)
        XCTAssertEqual(transition(all, next: all), .advance)
    }

    func testDifferentModeRearmsStickyPicker() {
        XCTAssertEqual(
            transition(
                identity(.allWindows, sticky: true),
                next: identity(.currentApp, sticky: true)
            ),
            .arm
        )
    }

    func testCurrentSpaceScopeChangeRearms() {
        XCTAssertEqual(
            transition(
                identity(.allWindows, sticky: true),
                next: identity(.allWindows, sticky: true, currentSpaceOnly: true)
            ),
            .arm
        )
    }

    func testStickySemanticChangeRearms() {
        XCTAssertEqual(
            transition(
                identity(.allWindows, sticky: true),
                next: identity(.allWindows, sticky: false)
            ),
            .arm
        )
    }

    private func identity(
        _ mode: PickerMode,
        sticky: Bool = false,
        currentSpaceOnly: Bool = false
    ) -> PickerArmTransitionPolicy.Identity {
        .init(mode: mode, sticky: sticky, currentSpaceOnly: currentSpaceOnly)
    }

    private func transition(
        _ current: PickerArmTransitionPolicy.Identity?,
        next: PickerArmTransitionPolicy.Identity
    ) -> PickerArmTransitionPolicy.Action {
        PickerArmTransitionPolicy.action(current: current, next: next)
    }
}
