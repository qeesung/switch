import CoreGraphics
import Foundation

enum PickerKeyInterpreter {
    enum Action: Equatable {
        case closeSelected
        case closeSelectedApp
        case hideSelected
        case openSettings
        case pickIndex(Int)
        case appendFilter(Character)
    }

    private static let keypadDigits: [CGKeyCode] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
    private static let asciiDigits = Array("123456789")

    /// Interprets printable picker commands from the character produced by the active
    /// keyboard layout. `keyCode` is only used for the layout-independent number pad.
    static func action(
        logicalCharacter: Character?,
        keyCode: CGKeyCode,
        actionModifierMatches: Bool,
        settingsModifierMatches: Bool,
        typeToFilter: Bool
    ) -> Action? {
        let character = logicalCharacter.flatMap { String($0).lowercased().first }

        if actionModifierMatches {
            switch character {
            case "w": return .closeSelected
            case "q": return .closeSelectedApp
            case "h": return .hideSelected
            default: break
            }
        }

        if settingsModifierMatches, character == "," {
            return .openSettings
        }

        if let index = keypadDigits.firstIndex(of: keyCode) {
            return .pickIndex(index)
        }
        if let character, let index = asciiDigits.firstIndex(of: character) {
            return .pickIndex(index)
        }

        if typeToFilter, let character,
           character.isLetter || character == " " || character == "-" || character == "." {
            return .appendFilter(character)
        }
        return nil
    }

    /// Decode from keyCode + the cached active layout. Never read CGEvent's
    /// associated Unicode string: Option/Control may already have changed it,
    /// and mutating event.flags does not translate that string again.
    static func logicalCharacter(
        from event: CGEvent,
        translator: KeyboardLayoutTranslator
    ) -> Character? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return translator.character(for: keyCode, shift: event.flags.contains(.maskShift))
    }
}
