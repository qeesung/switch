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
    @MainActor
    static func resolve(_ choice: SwitchPreferences.PickerDisplay) -> PickerScreenResolution? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let activeDisplayID = NSScreen.main.flatMap(displayID(for:))
        let primaryDisplayID = CGMainDisplayID()
        let paired: [(screen: NSScreen, candidate: PickerScreenSelectionPolicy.ScreenCandidate)] = screens.compactMap { screen in
            guard let displayID = displayID(for: screen) else { return nil }
            return (
                screen,
                PickerScreenSelectionPolicy.ScreenCandidate(
                    displayID: displayID,
                    frame: screen.frame,
                    isActive: displayID == activeDisplayID,
                    isPrimary: displayID == primaryDisplayID,
                    displayUUID: displayUUID(for: displayID)
                )
            )
        }
        guard let selected = PickerScreenSelectionPolicy.select(
            choice,
            from: paired.map(\.candidate),
            mouseLocation: NSEvent.mouseLocation
        ), let screen = paired.first(where: { $0.candidate.displayID == selected.displayID })?.screen else {
            return nil
        }

        let managedDisplays = readManagedDisplays()
        let managedDisplay = PickerScreenSelectionPolicy.matchManagedDisplay(
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

    private static func readManagedDisplays() -> [PickerScreenSelectionPolicy.ManagedDisplay] {
        let cid = CGSMainConnectionID()
        let raw = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        return PickerScreenSelectionPolicy.managedDisplays(from: raw)
    }
}
