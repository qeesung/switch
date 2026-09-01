import Carbon.HIToolbox
import CoreGraphics
import XCTest

final class KeyboardLayoutTranslatorTests: XCTestCase {
    @MainActor
    func testLogicalCharacterIgnoresEventsAssociatedOptionString() throws {
        KeyboardLayoutTranslator.shared.refresh()
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: source,
            virtualKey: 13,
            keyDown: true
        ))
        event.flags = .maskAlternate
        let injected = Array("∑".utf16)
        event.keyboardSetUnicodeString(stringLength: injected.count, unicodeString: injected)

        let expected = try XCTUnwrap(
            KeyboardLayoutTranslator.shared.character(for: 13, shift: false)
        )
        let actual = PickerKeyInterpreter.logicalCharacter(
            from: event,
            translator: .shared
        )

        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, "∑")
    }

    func testFrenchLayoutTranslatesLogicalCommandsAndShiftDigits() throws {
        guard let sourceList = TISCreateInputSourceList([
            kTISPropertyInputSourceID: "com.apple.keylayout.French"
        ] as CFDictionary, true) else {
            throw XCTSkip("Could not enumerate built-in keyboard layouts")
        }
        let sources = sourceList.takeRetainedValue() as NSArray
        guard let sourceObject = sources.firstObject else {
            throw XCTSkip("Built-in French keyboard layout is unavailable")
        }
        let source = sourceObject as! TISInputSource
        guard let data = KeyboardLayoutTranslator.layoutData(from: source) else {
            throw XCTSkip("French layout has no Unicode layout data")
        }
        let keyboardType = UInt32(LMGetKbdType())

        XCTAssertEqual(KeyboardLayoutTranslator.character(
            for: 6, shift: false, layoutData: data, keyboardType: keyboardType
        ), "w")
        XCTAssertEqual(KeyboardLayoutTranslator.character(
            for: 0, shift: false, layoutData: data, keyboardType: keyboardType
        ), "q")
        XCTAssertEqual(KeyboardLayoutTranslator.character(
            for: 46, shift: false, layoutData: data, keyboardType: keyboardType
        ), ",")
        XCTAssertEqual(KeyboardLayoutTranslator.character(
            for: 18, shift: true, layoutData: data, keyboardType: keyboardType
        ), "1")
    }
}
