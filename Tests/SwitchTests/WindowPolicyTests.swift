import ApplicationServices
import CoreGraphics
import XCTest
@testable import Switch

final class WindowPolicyTests: XCTestCase {
    func testStageManagerAllowsOnlyTitledSmallWindows() {
        let small = CGRect(x: 0, y: 0, width: 78, height: 109)

        XCTAssertTrue(StageManagerWindowPolicy.accepts(
            bounds: small,
            title: "Reminders",
            stageManagerEnabled: true
        ))
        XCTAssertFalse(StageManagerWindowPolicy.accepts(
            bounds: small,
            title: "",
            stageManagerEnabled: true
        ))
        XCTAssertFalse(StageManagerWindowPolicy.accepts(
            bounds: small,
            title: "Reminders",
            stageManagerEnabled: false
        ))
    }

    func testNormalBoundsKeepExistingBehavior() {
        XCTAssertTrue(StageManagerWindowPolicy.accepts(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 80),
            title: "",
            stageManagerEnabled: false
        ))
    }

    func testNoSpaceWindowRequiresStageManagerAndExactAXEvidence() {
        XCTAssertTrue(StageManagerWindowPolicy.keepsNoSpaceWindow(
            stageManagerEnabled: true,
            currentlyAXBacked: false,
            historicallyAXBacked: true
        ))
        XCTAssertTrue(StageManagerWindowPolicy.keepsNoSpaceWindow(
            stageManagerEnabled: true,
            currentlyAXBacked: true,
            historicallyAXBacked: false
        ))
        XCTAssertFalse(StageManagerWindowPolicy.keepsNoSpaceWindow(
            stageManagerEnabled: true,
            currentlyAXBacked: false,
            historicallyAXBacked: false
        ))
        XCTAssertFalse(StageManagerWindowPolicy.keepsNoSpaceWindow(
            stageManagerEnabled: false,
            currentlyAXBacked: true,
            historicallyAXBacked: true
        ))
    }

    func testAXCachePurgesAgainstCompleteSweepIDs() {
        let keptID = CGWindowID.max - 1
        let removedID = CGWindowID.max
        let element = AXUIElementCreateSystemWide()
        AXWindowCache.store(element, for: keptID)
        AXWindowCache.store(element, for: removedID)

        AXWindowCache.purge(keeping: [keptID])

        XCTAssertNotNil(AXWindowCache.element(for: keptID))
        XCTAssertNil(AXWindowCache.element(for: removedID))
        AXWindowCache.purge(keeping: [])
    }

    func testPickerDisplayChoiceResolvesMouseActiveAndPrimaryIndependently() {
        let primary = PickerScreenResolver.ScreenCandidate(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isActive: false,
            isPrimary: true,
            displayUUID: "PRIMARY-UUID"
        )
        let active = PickerScreenResolver.ScreenCandidate(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 100, height: 100),
            isActive: true,
            isPrimary: false,
            displayUUID: "ACTIVE-UUID"
        )
        let screens = [primary, active]

        XCTAssertEqual(PickerScreenResolver.select(
            .mouse,
            from: screens,
            mouseLocation: CGPoint(x: 150, y: 50)
        )?.displayID, 2)
        XCTAssertEqual(PickerScreenResolver.select(
            .active,
            from: screens,
            mouseLocation: .zero
        )?.displayID, 2)
        XCTAssertEqual(PickerScreenResolver.select(
            .primary,
            from: screens,
            mouseLocation: .zero
        )?.displayID, 1)
    }

    func testDisplayUUIDSelectsThatDisplaysCurrentSpace() {
        let displays = [
            PickerScreenResolver.ManagedDisplay(
                identifier: "PRIMARY-UUID",
                currentSpaceID: 1044
            ),
            PickerScreenResolver.ManagedDisplay(
                identifier: "active-uuid",
                currentSpaceID: 1279
            ),
        ]

        let match = PickerScreenResolver.matchManagedDisplay(
            displayUUID: "ACTIVE-UUID",
            isPrimary: false,
            from: displays
        )

        XCTAssertEqual(match?.identifier, "active-uuid")
        XCTAssertEqual(match?.currentSpaceID, 1279)
    }

    func testManagedDisplayParserReadsCurrentSpaceIDs() {
        let parsed = PickerScreenResolver.managedDisplays(from: [
            [
                "Display Identifier": "DISPLAY-A",
                "Current Space": ["id64": NSNumber(value: 1044)],
            ],
            [
                "Display Identifier": "DISPLAY-B",
                "Current Space": ["ManagedSpaceID": 1279],
            ],
        ])

        XCTAssertEqual(parsed, [
            PickerScreenResolver.ManagedDisplay(identifier: "DISPLAY-A", currentSpaceID: 1044),
            PickerScreenResolver.ManagedDisplay(identifier: "DISPLAY-B", currentSpaceID: 1279),
        ])
    }

    func testPrimaryDisplaySupportsMainManagedIdentifierFallback() {
        let displays = [
            PickerScreenResolver.ManagedDisplay(identifier: "Main", currentSpaceID: 42),
        ]

        XCTAssertEqual(PickerScreenResolver.matchManagedDisplay(
            displayUUID: "UUID-NOT-EXPOSED-BY-CGS",
            isPrimary: true,
            from: displays
        )?.currentSpaceID, 42)
        XCTAssertNil(PickerScreenResolver.matchManagedDisplay(
            displayUUID: "UUID-NOT-EXPOSED-BY-CGS",
            isPrimary: false,
            from: displays
        ))
    }

    func testPickerSpaceFilterKeepsOnlyTargetClaimsAndNoSpaceCompatibilityWindows() {
        XCTAssertTrue(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [10, 20],
            isMinimized: false,
            isHidden: false,
            targetSpaceID: 20
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [10],
            isMinimized: false,
            isHidden: false,
            targetSpaceID: 20
        ))
        XCTAssertTrue(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: true,
            isHidden: false,
            targetSpaceID: 20
        ))
        XCTAssertTrue(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: true,
            targetSpaceID: 20
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: false,
            targetSpaceID: 20
        ))
    }
}
