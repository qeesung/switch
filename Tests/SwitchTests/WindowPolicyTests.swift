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
}
