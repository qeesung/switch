import AppKit
import CoreGraphics
import XCTest

final class PickerInputRoutingPolicyTests: XCTestCase {
    func testNativeEditingNeedsFocusedReleasedStickySession() {
        XCTAssertTrue(nativeEditing(focused: true, sticky: true, released: true))
        XCTAssertFalse(nativeEditing(focused: false, sticky: true, released: true))
        XCTAssertFalse(nativeEditing(focused: true, sticky: false, released: true))
        XCTAssertFalse(nativeEditing(focused: true, sticky: true, released: false))
    }

    func testEveryInvocationModifierMustBeReleasedBeforeNativeEditing() {
        let required: CGEventFlags = [.maskCommand, .maskAlternate]
        XCTAssertFalse(PickerInputRoutingPolicy.allInvocationModifiersReleased(
            required: required,
            current: .maskCommand
        ))
        XCTAssertFalse(PickerInputRoutingPolicy.allInvocationModifiersReleased(
            required: required,
            current: .maskAlternate
        ))
        XCTAssertTrue(PickerInputRoutingPolicy.allInvocationModifiersReleased(
            required: required,
            current: .maskShift
        ))
    }

    func testRepeatedAdvanceWaitsForItsOwnModifierRelease() {
        let required: CGEventFlags = [.maskAlternate]
        var released = true

        released = PickerInputRoutingPolicy.updatedStickyModifiersReleased(
            released,
            hotkeyMatched: true,
            required: required,
            current: required
        )
        XCTAssertFalse(released)

        released = PickerInputRoutingPolicy.updatedStickyModifiersReleased(
            released,
            hotkeyMatched: false,
            required: required,
            current: required
        )
        XCTAssertFalse(released)

        released = PickerInputRoutingPolicy.updatedStickyModifiersReleased(
            released,
            hotkeyMatched: false,
            required: required,
            current: []
        )
        XCTAssertTrue(released)
    }

    func testLaterHardwareSnapshotRecoversMissedStickyRelease() {
        let required: CGEventFlags = [.maskCommand]
        XCTAssertTrue(PickerInputRoutingPolicy.updatedStickyModifiersReleased(
            false,
            hotkeyMatched: false,
            required: required,
            current: []
        ))
    }

    func testSelectAllAndStandardEditingReachNativeSearchField() {
        // Cmd+A is interpreted as appendFilter("a") by the legacy path. Once the
        // native editor is ready, that result must be forwarded instead of appended.
        let commandA = PickerKeyInterpreter.action(
            logicalCharacter: "a",
            keyCode: 0,
            actionModifierMatches: true,
            settingsModifierMatches: true,
            typeToFilter: true
        )
        XCTAssertEqual(commandA, .appendFilter("a"))
        XCTAssertEqual(route(action: commandA), .searchField)
        XCTAssertEqual(route(action: nil), .searchField) // Delete, cursor, or other editor binding
    }

    func testSelectAllIsRecognizedBeforeNativeFieldBecomesReady() {
        XCTAssertTrue(PickerInputRoutingPolicy.isSelectAllCommand(
            stickySession: true,
            typeToFilter: true,
            commandHeld: true,
            logicalCharacter: "A"
        ))
        XCTAssertFalse(PickerInputRoutingPolicy.isSelectAllCommand(
            stickySession: false,
            typeToFilter: true,
            commandHeld: true,
            logicalCharacter: "a"
        ))
        XCTAssertFalse(PickerInputRoutingPolicy.isSelectAllCommand(
            stickySession: true,
            typeToFilter: true,
            commandHeld: false,
            logicalCharacter: "a"
        ))
    }

    func testStandardEditingCommandsAreRecognizedBeforeFocusIsReady() {
        let expected: [(Character, Bool, PickerInputRoutingPolicy.SearchEditingCommand)] = [
            ("a", false, .selectAll),
            ("c", false, .copy),
            ("v", false, .paste),
            ("x", false, .cut),
            ("z", false, .undo),
            ("z", true, .redo)
        ]
        for (character, shift, command) in expected {
            XCTAssertEqual(
                PickerInputRoutingPolicy.searchEditingCommand(
                    stickySession: true,
                    typeToFilter: true,
                    commandHeld: true,
                    shiftHeld: shift,
                    logicalCharacter: character
                ),
                command
            )
        }
        XCTAssertNil(PickerInputRoutingPolicy.searchEditingCommand(
            stickySession: false,
            typeToFilter: true,
            commandHeld: true,
            shiftHeld: false,
            logicalCharacter: "v"
        ))
    }

    func testNativePickerCommandsUseOrderedAppKitEvents() {
        XCTAssertEqual(route(action: .closeSelected), .orderedPicker)
        XCTAssertEqual(route(action: .closeSelectedApp), .orderedPicker)
        XCTAssertEqual(route(action: .hideSelected), .orderedPicker)
        XCTAssertEqual(route(action: .openSettings), .orderedPicker)
        XCTAssertEqual(route(action: .pickIndex(0)), .orderedPicker)
        XCTAssertEqual(route(action: nil), .searchField)
    }

    func testOrderedPickerEventCodecRoundTripsKeyAndModifiers() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let encoded = PickerInputRoutingPolicy.orderedEventUserData(
            kind: .pickerCommand,
            keyCode: 48,
            flags: flags
        )
        XCTAssertEqual(
            PickerInputRoutingPolicy.orderedKeyEvent(from: encoded),
            .init(kind: .pickerCommand, keyCode: 48, flags: flags)
        )
        XCTAssertNil(PickerInputRoutingPolicy.orderedKeyEvent(from: 0))
        let invalidKind = Int64(bitPattern: 0x535f_0000_0000_0000)
        XCTAssertNil(PickerInputRoutingPolicy.orderedKeyEvent(from: invalidKind))
    }

    func testOrderedPickerMarkerSurvivesCGEventToNSEventBridge() throws {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let encoded = PickerInputRoutingPolicy.orderedEventUserData(
            kind: .hotkey,
            keyCode: 13,
            flags: flags
        )
        let cgEvent = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 13,
            keyDown: true
        ))
        cgEvent.setIntegerValueField(.eventSourceUserData, value: encoded)
        cgEvent.setIntegerValueField(.keyboardEventKeycode, value: 90)
        cgEvent.flags = []

        let nsEvent = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        let bridged = try XCTUnwrap(nsEvent.cgEvent)
        XCTAssertEqual(
            PickerInputRoutingPolicy.orderedKeyEvent(
                from: bridged.getIntegerValueField(.eventSourceUserData)
            ),
            .init(kind: .hotkey, keyCode: 13, flags: flags)
        )
        XCTAssertEqual(nsEvent.keyCode, 90)
        XCTAssertFalse(nsEvent.modifierFlags.contains(.command))
    }

    func testReplayedKeyEventCodecPreservesFenceGeneration() {
        let generation: UInt64 = 0x1234_5678_9abc
        let encoded = PickerInputRoutingPolicy.replayedKeyEventUserData(
            generation: generation
        )
        XCTAssertEqual(
            PickerInputRoutingPolicy.replayedKeyEventGeneration(from: encoded),
            generation
        )
        XCTAssertNil(PickerInputRoutingPolicy.replayedKeyEventGeneration(from: 0))
        XCTAssertNil(PickerInputRoutingPolicy.replayedKeyEventGeneration(
            from: PickerInputRoutingPolicy.orderedEventUserData(
                kind: .hotkey,
                keyCode: 48,
                flags: .maskCommand
            )
        ))

        let sentinel = PickerInputRoutingPolicy.replaySentinelUserData(
            generation: generation
        )
        XCTAssertEqual(
            PickerInputRoutingPolicy.replaySentinelGeneration(from: sentinel),
            generation
        )
        XCTAssertNil(PickerInputRoutingPolicy.replayedKeyEventGeneration(from: sentinel))
        XCTAssertNil(PickerInputRoutingPolicy.replaySentinelGeneration(from: encoded))
    }

    func testHoldModeKeepsLegacyFilteringAndFailsClosedWhileFieldFocusSettles() {
        XCTAssertEqual(
            PickerInputRoutingPolicy.route(
                nativeEditingAvailable: false,
                pickerAction: .appendFilter("a")
            ),
            .picker
        )
        XCTAssertEqual(
            PickerInputRoutingPolicy.route(
                nativeEditingAvailable: false,
                pickerAction: nil
            ),
            .discard
        )
    }

    private func nativeEditing(focused: Bool, sticky: Bool, released: Bool) -> Bool {
        PickerInputRoutingPolicy.nativeEditingAvailable(
            searchFieldFocused: focused,
            stickySession: sticky,
            stickyModifiersReleased: released
        )
    }

    private func route(action: PickerKeyInterpreter.Action?) -> PickerInputRoutingPolicy.Route {
        PickerInputRoutingPolicy.route(
            nativeEditingAvailable: true,
            pickerAction: action
        )
    }
}
