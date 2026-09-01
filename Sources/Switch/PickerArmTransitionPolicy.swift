enum PickerArmTransitionPolicy {
    struct Identity: Equatable {
        let mode: HotkeyManager.Mode
        let sticky: Bool
        let currentSpaceOnly: Bool
    }

    enum Action: Equatable {
        case arm
        case advance
    }

    /// Repeated triggers with the same picker semantics advance selection.
    /// A shortcut requesting a different scope/session is a new invocation and
    /// must not be swallowed by the still-armed sticky picker.
    static func action(current: Identity?, next: Identity) -> Action {
        current == next ? .advance : .arm
    }
}
