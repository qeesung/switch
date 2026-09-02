import AppKit
import XCTest

final class PickerSearchFieldAppearanceTests: XCTestCase {
    func testAppearanceUsesNativeLargeRoundedSearchField() throws {
        let field = NSSearchField()
        PickerSearchFieldAppearance.apply(to: field, visualScale: 1.2)

        XCTAssertTrue(field.isBezeled)
        XCTAssertEqual(field.bezelStyle, .roundedBezel)
        XCTAssertEqual(field.focusRingType, .default)
        XCTAssertEqual(field.controlSize, .large)
        XCTAssertEqual(try XCTUnwrap(field.font).pointSize, 16.8, accuracy: 0.001)
    }

    func testNativeCellKeepsSearchIconOutsideTextAtSupportedWidths() throws {
        for width in [220.0 * 0.9, 360.0, 480.0 * 1.2] {
            let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: width, height: 41))
            PickerSearchFieldAppearance.apply(to: field, visualScale: 1.2)
            let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
            let searchRect = cell.searchButtonRect(forBounds: field.bounds)
            let textRect = cell.searchTextRect(forBounds: field.bounds)

            XCTAssertLessThanOrEqual(searchRect.maxX, textRect.minX, "overlap at width \(width)")
        }
    }
}
