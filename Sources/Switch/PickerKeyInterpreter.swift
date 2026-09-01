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

    /// Decode on the event-tap thread without touching NSEvent/TSM. Command, Option,
    /// and Control are removed so shortcuts still yield their layout's printable key;
    /// Shift remains because it is required for uppercase letters and digits on layouts
    /// such as French AZERTY.
    static func logicalCharacter(from event: CGEvent) -> Character? {
        guard let copy = event.copy() else { return nil }
        copy.flags = copy.flags.intersection(.maskShift)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        copy.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length).first
    }
}
