import CoreGraphics

/// Decides whether a picker key stays in the picker, goes to the native search
/// field editor, or is ignored. The event tap calls this without touching AppKit
/// state from its background thread.
enum PickerInputRoutingPolicy {
    enum SearchEditingCommand: Equatable {
        case selectAll
        case copy
        case paste
        case cut
        case undo
        case redo
    }

    enum Route: Equatable {
        case picker
        case searchField
        /// The event tap rewrites this command into a harmless marker event.
        /// AppKit then executes it in order with the field editor's text events.
        case orderedPicker
        case discard
    }

    enum OrderedEventKind: UInt64, Equatable {
        case pickerCommand = 1
        case hotkey = 2
        case terminal = 3
    }

    struct OrderedKeyEvent: Equatable {
        let kind: OrderedEventKind
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private static let orderedEventMagic: UInt64 = 0x535
    private static let orderedEventMagicShift: UInt64 = 52
    private static let orderedEventKindShift: UInt64 = 48
    private static let orderedEventKeyCodeShift: UInt64 = 32
    private static let orderedEventFlagsMask: UInt64 = 0xffff_ffff
    private static let replayedEventMagic: UInt64 = 0x5250
    private static let replaySentinelMagic: UInt64 = 0x5251
    private static let replayedEventMagicShift: UInt64 = 48
    private static let replayedEventGenerationMask: UInt64 = 0x0000_ffff_ffff_ffff

    private static let primaryModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl
    ]

    static func allInvocationModifiersReleased(
        required: CGEventFlags,
        current: CGEventFlags
    ) -> Bool {
        let invocationModifiers = required.intersection(primaryModifiers)
        return current.intersection(invocationModifiers).isEmpty
    }

    static func updatedStickyModifiersReleased(
        _ wasReleased: Bool,
        hotkeyMatched: Bool,
        required: CGEventFlags,
        current: CGEventFlags
    ) -> Bool {
        if hotkeyMatched { return false }
        return wasReleased || allInvocationModifiersReleased(required: required, current: current)
    }

    /// Hold-style pickers keep their invocation modifier pressed while filtering,
    /// so forwarding their raw events would turn letters into Command/Option
    /// shortcuts. Native editing starts only after a sticky invocation's original
    /// modifier chord has been released once.
    static func nativeEditingAvailable(
        searchFieldFocused: Bool,
        stickySession: Bool,
        stickyModifiersReleased: Bool
    ) -> Bool {
        searchFieldFocused && stickySession && stickyModifiersReleased
    }

    static func isSelectAllCommand(
        stickySession: Bool,
        typeToFilter: Bool,
        commandHeld: Bool,
        logicalCharacter: Character?
    ) -> Bool {
        guard stickySession, typeToFilter, commandHeld, let logicalCharacter else { return false }
        return String(logicalCharacter).lowercased() == "a"
    }

    static func searchEditingCommand(
        stickySession: Bool,
        typeToFilter: Bool,
        commandHeld: Bool,
        shiftHeld: Bool,
        logicalCharacter: Character?
    ) -> SearchEditingCommand? {
        guard stickySession, typeToFilter, commandHeld, let logicalCharacter else { return nil }
        switch String(logicalCharacter).lowercased() {
        case "a": return .selectAll
        case "c": return .copy
        case "v": return .paste
        case "x": return .cut
        case "z": return shiftHeld ? .redo : .undo
        default: return nil
        }
    }

    /// In native mode, ordinary editing keys go straight to the field. Picker
    /// commands are rewritten as ordered marker events so they cannot overtake a
    /// preceding character that AppKit has not put into the field editor yet.
    static func route(
        nativeEditingAvailable: Bool,
        pickerAction: PickerKeyInterpreter.Action?,
        commandHeld: Bool = false
    ) -> Route {
        if nativeEditingAvailable {
            switch pickerAction {
            case .pickIndex:
                // A focused search field must accept digits, including the
                // number keys used to choose Chinese input-method candidates.
                // Command-number remains an explicit picker shortcut.
                return commandHeld ? .orderedPicker : .searchField
            case .closeSelected, .closeSelectedApp, .hideSelected, .openSettings:
                return .orderedPicker
            case .appendFilter, nil:
                return .searchField
            }
        }

        if pickerAction != nil {
            return .picker
        }
        // A field editor can briefly exist before the sticky modifier release is
        // observed. Fail closed so raw modified keys never leak into either app.
        return .discard
    }

    static func orderedEventUserData(
        kind: OrderedEventKind,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Int64 {
        let encoded = (orderedEventMagic << orderedEventMagicShift)
            | (kind.rawValue << orderedEventKindShift)
            | (UInt64(keyCode) << orderedEventKeyCodeShift)
            | (flags.rawValue & orderedEventFlagsMask)
        return Int64(bitPattern: encoded)
    }

    static func orderedKeyEvent(from userData: Int64) -> OrderedKeyEvent? {
        let encoded = UInt64(bitPattern: userData)
        guard encoded >> orderedEventMagicShift == orderedEventMagic else { return nil }
        guard let kind = OrderedEventKind(
            rawValue: (encoded >> orderedEventKindShift) & 0xf
        ) else { return nil }
        let keyCode = CGKeyCode((encoded >> orderedEventKeyCodeShift) & 0xffff)
        let flags = CGEventFlags(rawValue: encoded & orderedEventFlagsMask)
        return OrderedKeyEvent(kind: kind, keyCode: keyCode, flags: flags)
    }

    /// Tags a replay with the fence that originally buffered it. A replayed
    /// hotkey can create a newer fence; remaining events from the old batch must
    /// then be buffered by that new fence instead of bypassing it.
    static func replayedKeyEventUserData(generation: UInt64) -> Int64 {
        let encoded = (replayedEventMagic << replayedEventMagicShift)
            | (generation & replayedEventGenerationMask)
        return Int64(bitPattern: encoded)
    }

    static func replayedKeyEventGeneration(from userData: Int64) -> UInt64? {
        let encoded = UInt64(bitPattern: userData)
        guard encoded >> replayedEventMagicShift == replayedEventMagic else { return nil }
        return encoded & replayedEventGenerationMask
    }

    static func replaySentinelUserData(generation: UInt64) -> Int64 {
        let encoded = (replaySentinelMagic << replayedEventMagicShift)
            | (generation & replayedEventGenerationMask)
        return Int64(bitPattern: encoded)
    }

    static func replaySentinelGeneration(from userData: Int64) -> UInt64? {
        let encoded = UInt64(bitPattern: userData)
        guard encoded >> replayedEventMagicShift == replaySentinelMagic else { return nil }
        return encoded & replayedEventGenerationMask
    }
}
