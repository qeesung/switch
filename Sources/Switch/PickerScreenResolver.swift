import AppKit
import ApplicationServices
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
        let displayBounds = activeDisplayBounds()
        let legacyActiveDisplayID = NSScreen.main.flatMap(displayID(for:))
        // Mouse normally resolves directly from the cursor and Primary never
        // needs AX. Only pay the focused-window lookup cost for Active.
        let activeDisplayID = choice == .active
            ? focusedDisplayID(in: displayBounds) ?? legacyActiveDisplayID
            : legacyActiveDisplayID
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

    /// Resolve Active from the frontmost application's focused window when it
    /// is available. This also gives us explicit, testable geometry for the
    /// same display decision used by panel placement and Space filtering.
    private static func focusedDisplayID(
        in displays: [PickerScreenSelectionPolicy.DisplayBoundsCandidate]
    ) -> CGDirectDisplayID? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        if let focusedBounds = focusedWindowBounds(of: frontmost.processIdentifier),
           let displayID = PickerScreenSelectionPolicy.displayContainingMost(
               of: focusedBounds,
               from: displays
           ) {
            return displayID
        }
        return PickerScreenSelectionPolicy.activeDisplayID(
            focusedWindowBounds: nil,
            fallbackWindowBounds: frontmostCGWindowBounds(
                of: frontmost.processIdentifier
            ),
            from: displays
        )
    }

    private static func focusedWindowBounds(of pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let appAX = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appAX, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appAX,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = focusedRef as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(focused, 0.2)
        // Prefer the exact WindowServer frame. It needs one AX round-trip for
        // the window ID instead of separate position and size calls.
        if let windowID = AXHelpers.windowID(of: focused),
           let frame = cgWindowBounds(windowID) {
            return frame
        }
        return axWindowBounds(focused)
    }

    private static func axWindowBounds(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionRef
        ) == .success,
              AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &sizeRef
              ) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Some applications do not expose AXFocusedWindow. CGWindowList is
    /// ordered front-to-back, so retain valid on-screen layer-0 frames owned by
    /// the frontmost process in that order.
    private static func frontmostCGWindowBounds(of pid: pid_t) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else {
                return nil
            }
            return cgWindowBounds(from: window)
        }
    }

    private static func cgWindowBounds(_ windowID: CGWindowID) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[String: Any]] ?? []
        return windows.first.flatMap(cgWindowBounds(from:))
    }

    private static func cgWindowBounds(from window: [String: Any]) -> CGRect? {
        guard let rawBounds = window[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
        guard let frame, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private static func activeDisplayBounds()
        -> [PickerScreenSelectionPolicy.DisplayBoundsCandidate] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }
        return displayIDs.prefix(Int(count)).map {
            PickerScreenSelectionPolicy.DisplayBoundsCandidate(
                displayID: $0,
                bounds: CGDisplayBounds($0)
            )
        }
    }

    private static func readManagedDisplays() -> [PickerScreenSelectionPolicy.ManagedDisplay] {
        let cid = CGSMainConnectionID()
        let raw = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        return PickerScreenSelectionPolicy.managedDisplays(from: raw)
    }
}
