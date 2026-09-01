import AppKit
import CoreGraphics

/// One Picker Display decision, captured when the hotkey arms. The same screen
/// positions the panel and supplies the Space used by current-Space filtering.
struct PickerScreenResolution {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let displayUUID: String?
    let managedDisplayIdentifier: String?
    let currentSpaceID: Int?
}

enum PickerScreenResolver {
    struct ScreenCandidate: Equatable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let isActive: Bool
        let isPrimary: Bool
        let displayUUID: String?
    }

    struct ManagedDisplay: Equatable {
        let identifier: String
        let currentSpaceID: Int?
    }

    @MainActor
    static func resolve(_ choice: SwitchPreferences.PickerDisplay) -> PickerScreenResolution? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let activeDisplayID = NSScreen.main.flatMap(displayID(for:))
        let primaryDisplayID = CGMainDisplayID()
        let paired: [(screen: NSScreen, candidate: ScreenCandidate)] = screens.compactMap { screen in
            guard let displayID = displayID(for: screen) else { return nil }
            return (
                screen,
                ScreenCandidate(
                    displayID: displayID,
                    frame: screen.frame,
                    isActive: displayID == activeDisplayID,
                    isPrimary: displayID == primaryDisplayID,
                    displayUUID: displayUUID(for: displayID)
                )
            )
        }
        guard let selected = select(
            choice,
            from: paired.map(\.candidate),
            mouseLocation: NSEvent.mouseLocation
        ), let screen = paired.first(where: { $0.candidate.displayID == selected.displayID })?.screen else {
            return nil
        }

        let managedDisplays = readManagedDisplays()
        let managedDisplay = matchManagedDisplay(
            displayUUID: selected.displayUUID,
            isPrimary: selected.isPrimary,
            from: managedDisplays
        )
        return PickerScreenResolution(
            screen: screen,
            displayID: selected.displayID,
            displayUUID: selected.displayUUID,
            managedDisplayIdentifier: managedDisplay?.identifier,
            currentSpaceID: managedDisplay?.currentSpaceID
        )
    }

    static func select(
        _ choice: SwitchPreferences.PickerDisplay,
        from candidates: [ScreenCandidate],
        mouseLocation: CGPoint
    ) -> ScreenCandidate? {
        guard !candidates.isEmpty else { return nil }
        switch choice {
        case .mouse:
            return candidates.first(where: { $0.frame.contains(mouseLocation) })
                ?? candidates.first(where: \.isActive)
                ?? candidates.first(where: \.isPrimary)
                ?? candidates.first
        case .active:
            return candidates.first(where: \.isActive)
                ?? candidates.first(where: \.isPrimary)
                ?? candidates.first
        case .primary:
            return candidates.first(where: \.isPrimary) ?? candidates.first
        }
    }

    static func matchManagedDisplay(
        displayUUID: String?,
        isPrimary: Bool,
        from displays: [ManagedDisplay]
    ) -> ManagedDisplay? {
        if let displayUUID,
           let exact = displays.first(where: {
               $0.identifier.caseInsensitiveCompare(displayUUID) == .orderedSame
           }) {
            return exact
        }
        // Some macOS releases call the primary managed display "Main" instead
        // of exposing the UUID returned by CGDisplayCreateUUIDFromDisplayID.
        if isPrimary {
            return displays.first(where: {
                $0.identifier.caseInsensitiveCompare("Main") == .orderedSame
            })
        }
        return nil
    }

    static func managedDisplays(from raw: [[String: Any]]) -> [ManagedDisplay] {
        raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let current = display["Current Space"] as? [String: Any]
            return ManagedDisplay(
                identifier: identifier,
                currentSpaceID: integer(
                    from: current?["id64"] ?? current?["ManagedSpaceID"]
                )
            )
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(kCFAllocatorDefault, value) as String
    }

    private static func readManagedDisplays() -> [ManagedDisplay] {
        let cid = CGSMainConnectionID()
        let raw = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        return managedDisplays(from: raw)
    }

    private static func integer(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? UInt64, value <= UInt64(Int.max) { return Int(value) }
        return nil
    }
}
