import CoreGraphics
import XCTest

final class PickerKeyInterpreterTests: XCTestCase {
    func testUSLayoutPrintableCommandsUseLogicalCharacters() {
        XCTAssertEqual(action("w", keyCode: 13, actionModifierMatches: true), .closeSelected)
        XCTAssertEqual(action("q", keyCode: 12, actionModifierMatches: true), .closeSelectedApp)
        XCTAssertEqual(action("h", keyCode: 4, actionModifierMatches: true), .hideSelected)
        XCTAssertEqual(action(",", keyCode: 43, settingsModifierMatches: true), .openSettings)
        XCTAssertEqual(action("1", keyCode: 18), .pickIndex(0))
        XCTAssertEqual(action("9", keyCode: 25), .pickIndex(8))
    }

    func testAZERTYUsesProducedCharacterInsteadOfQWERTYPhysicalPosition() {
        XCTAssertNil(action("z", keyCode: 13, actionModifierMatches: true))
        XCTAssertEqual(action("w", keyCode: 6, actionModifierMatches: true), .closeSelected)

        XCTAssertNil(action("a", keyCode: 12, actionModifierMatches: true))
        XCTAssertEqual(action("q", keyCode: 0, actionModifierMatches: true), .closeSelectedApp)

        XCTAssertNil(action(";", keyCode: 43, settingsModifierMatches: true))
        XCTAssertEqual(action(",", keyCode: 46, settingsModifierMatches: true), .openSettings)

        XCTAssertNil(action("&", keyCode: 18))
        XCTAssertEqual(action("1", keyCode: 18), .pickIndex(0))
    }

    func testNumberPadRemainsKeyCodeBased() {
        XCTAssertEqual(action(nil, keyCode: 83), .pickIndex(0))
        XCTAssertEqual(action(nil, keyCode: 92), .pickIndex(8))
    }

    func testPrintableLetterFallsThroughToFilterWithoutActionModifier() {
        XCTAssertEqual(
            action("W", keyCode: 13, typeToFilter: true),
            .appendFilter("w")
        )
    }

    private func action(
        _ character: Character?,
        keyCode: CGKeyCode,
        actionModifierMatches: Bool = false,
        settingsModifierMatches: Bool = false,
        typeToFilter: Bool = false
    ) -> PickerKeyInterpreter.Action? {
        PickerKeyInterpreter.action(
            logicalCharacter: character,
            keyCode: keyCode,
            actionModifierMatches: actionModifierMatches,
            settingsModifierMatches: settingsModifierMatches,
            typeToFilter: typeToFilter
        )
    }
}
