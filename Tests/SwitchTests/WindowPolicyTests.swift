import ApplicationServices
import CoreGraphics
import XCTest

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
        XCTAssertFalse(StageManagerWindowPolicy.accepts(
            bounds: .zero,
            title: "Overlay",
            stageManagerEnabled: true
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
        let primary = PickerScreenSelectionPolicy.ScreenCandidate(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isActive: false,
            isPrimary: true,
            displayUUID: "PRIMARY-UUID"
        )
        let active = PickerScreenSelectionPolicy.ScreenCandidate(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 100, height: 100),
            isActive: true,
            isPrimary: false,
            displayUUID: "ACTIVE-UUID"
        )
        let screens = [primary, active]

        XCTAssertEqual(PickerScreenSelectionPolicy.select(
            .mouse,
            from: screens,
            mouseLocation: CGPoint(x: 150, y: 50)
        )?.displayID, 2)
        XCTAssertEqual(PickerScreenSelectionPolicy.select(
            .active,
            from: screens,
            mouseLocation: .zero
        )?.displayID, 2)
        XCTAssertEqual(PickerScreenSelectionPolicy.select(
            .primary,
            from: screens,
            mouseLocation: .zero
        )?.displayID, 1)
    }

    func testDisplayUUIDSelectsThatDisplaysCurrentSpace() {
        let displays = [
            PickerScreenSelectionPolicy.ManagedDisplay(
                identifier: "PRIMARY-UUID",
                currentSpaceID: 1044
            ),
            PickerScreenSelectionPolicy.ManagedDisplay(
                identifier: "active-uuid",
                currentSpaceID: 1279
            ),
        ]

        let match = PickerScreenSelectionPolicy.matchManagedDisplay(
            displayUUID: "ACTIVE-UUID",
            isPrimary: false,
            from: displays
        )

        XCTAssertEqual(match?.identifier, "active-uuid")
        XCTAssertEqual(match?.currentSpaceID, 1279)
    }

    func testManagedDisplayParserReadsCurrentSpaceIDs() {
        let parsed = PickerScreenSelectionPolicy.managedDisplays(from: [
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
            PickerScreenSelectionPolicy.ManagedDisplay(identifier: "DISPLAY-A", currentSpaceID: 1044),
            PickerScreenSelectionPolicy.ManagedDisplay(identifier: "DISPLAY-B", currentSpaceID: 1279),
        ])
    }

    func testPrimaryDisplaySupportsMainManagedIdentifierFallback() {
        let displays = [
            PickerScreenSelectionPolicy.ManagedDisplay(identifier: "Main", currentSpaceID: 42),
        ]

        XCTAssertEqual(PickerScreenSelectionPolicy.matchManagedDisplay(
            displayUUID: "UUID-NOT-EXPOSED-BY-CGS",
            isPrimary: true,
            from: displays
        )?.currentSpaceID, 42)
        XCTAssertNil(PickerScreenSelectionPolicy.matchManagedDisplay(
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
            isConfirmedStageManagerOffstage: false,
            targetSpaceID: 20
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [10],
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            targetSpaceID: 20
        ))
        XCTAssertTrue(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: true,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            targetSpaceID: 20
        ))
        XCTAssertTrue(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: true,
            isConfirmedStageManagerOffstage: false,
            targetSpaceID: 20
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            targetSpaceID: 20
        ))
    }

    func testConfirmedStageManagerNoSpaceWindowSurvivesPickerSpaceFilter() {
        let confirmedByExactAXEvidence = StageManagerWindowPolicy.keepsNoSpaceWindow(
            stageManagerEnabled: true,
            currentlyAXBacked: false,
            historicallyAXBacked: true
        )
        let rejectedWithoutAXEvidence = StageManagerWindowPolicy.keepsNoSpaceWindow(
            stageManagerEnabled: true,
            currentlyAXBacked: false,
            historicallyAXBacked: false
        )

        XCTAssertTrue(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: confirmedByExactAXEvidence,
            targetSpaceID: 20,
            windowDisplayID: 2,
            targetDisplayID: 2
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: confirmedByExactAXEvidence,
            targetSpaceID: 20,
            windowDisplayID: 1,
            targetDisplayID: 2
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includes(
            claimedSpaceIDs: [],
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: rejectedWithoutAXEvidence,
            targetSpaceID: 20
        ))
    }

    func testMissingManagedSpaceFallsBackToTargetDisplayOnly() {
        XCTAssertTrue(PickerSpaceWindowPolicy.includesWhenSpaceUnknown(
            isInActiveSweep: true,
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            windowDisplayID: 2,
            targetDisplayID: 2
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includesWhenSpaceUnknown(
            isInActiveSweep: true,
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            windowDisplayID: 1,
            targetDisplayID: 2
        ))
        XCTAssertFalse(PickerSpaceWindowPolicy.includesWhenSpaceUnknown(
            isInActiveSweep: false,
            isMinimized: false,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            windowDisplayID: 2,
            targetDisplayID: 2
        ))
        XCTAssertTrue(PickerSpaceWindowPolicy.includesWhenSpaceUnknown(
            isInActiveSweep: false,
            isMinimized: true,
            isHidden: false,
            isConfirmedStageManagerOffstage: false,
            windowDisplayID: nil,
            targetDisplayID: 2
        ))
    }

    func testFocusRelocationUsesInvocationDestinationSpace() {
        XCTAssertFalse(WindowFocusSpacePolicy.shouldMove(
            claimedSpaceIDs: [1279],
            legacyIsCrossSpace: true,
            resolvedDestinationSpaceID: 1279
        ))
        XCTAssertFalse(WindowFocusSpacePolicy.shouldMove(
            claimedSpaceIDs: [1044],
            legacyIsCrossSpace: false,
            resolvedDestinationSpaceID: 1279
        ))
        XCTAssertTrue(WindowFocusSpacePolicy.shouldMove(
            claimedSpaceIDs: [1044],
            legacyIsCrossSpace: true,
            resolvedDestinationSpaceID: 1279
        ))
        XCTAssertTrue(WindowFocusSpacePolicy.shouldMove(
            claimedSpaceIDs: [1044],
            legacyIsCrossSpace: true,
            resolvedDestinationSpaceID: nil
        ))
        XCTAssertFalse(WindowFocusSpacePolicy.shouldMove(
            claimedSpaceIDs: [],
            legacyIsCrossSpace: true,
            resolvedDestinationSpaceID: 1279
        ))
    }
}
