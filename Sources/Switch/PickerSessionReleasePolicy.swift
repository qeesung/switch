enum PickerSessionReleasePolicy {
    enum Action: Equatable {
        case commit
        case keepOpen
    }

    /// Releasing the arming modifiers only commits a regular picker session.
    /// Sticky sessions stay active regardless of how quickly the modifiers are released.
    static func action(isSticky: Bool) -> Action {
        isSticky ? .keepOpen : .commit
    }
}
