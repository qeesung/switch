import CoreGraphics
import Foundation

enum PickerDisplayChoice: String, CaseIterable, Identifiable {
    case mouse
    case active
    case primary

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .mouse:
            return LocalizedStringResource(
                "Picker display: Mouse",
                defaultValue: "Mouse",
                comment: "Picker display segmented control"
            )
        case .active:
            return LocalizedStringResource(
                "Picker display: Active",
                defaultValue: "Active",
                comment: "Picker display segmented control"
            )
        case .primary:
            return LocalizedStringResource(
                "Picker display: Primary",
                defaultValue: "Primary",
                comment: "Picker display segmented control"
            )
        }
    }
}

/// Pure display-selection and managed-Space parsing rules. Live AppKit/SkyLight
/// queries stay in PickerScreenResolver; this policy is safe for unhosted tests.
enum PickerScreenSelectionPolicy {
    struct DisplayBoundsCandidate: Equatable {
        let displayID: CGDirectDisplayID
        /// Quartz global coordinates (top-left origin), matching AX window frames.
        let bounds: CGRect
    }

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

    static func select(
        _ choice: PickerDisplayChoice,
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

    /// Resolves a window to the display containing most of it. AX window frames
    /// and `CGDisplayBounds` share Quartz global coordinates, unlike
    /// `NSScreen.frame`; keeping this math here prevents accidental coordinate
    /// mixing when resolving the Active picker display.
    static func displayContainingMost(
        of windowBounds: CGRect,
        from candidates: [DisplayBoundsCandidate]
    ) -> CGDirectDisplayID? {
        guard windowBounds.width > 0, windowBounds.height > 0 else { return nil }
        var best: (displayID: CGDirectDisplayID, area: CGFloat)?
        for candidate in candidates {
            let intersection = windowBounds.intersection(candidate.bounds)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area {
                best = (candidate.displayID, area)
            }
        }
        return best?.displayID
    }

    /// Prefer the focused AX window, then walk CGWindowList's front-to-back
    /// fallback frames until one can be mapped to an attached display.
    static func activeDisplayID(
        focusedWindowBounds: CGRect?,
        fallbackWindowBounds: [CGRect],
        from candidates: [DisplayBoundsCandidate]
    ) -> CGDirectDisplayID? {
        if let focusedWindowBounds,
           let displayID = displayContainingMost(
               of: focusedWindowBounds,
               from: candidates
           ) {
            return displayID
        }
        for bounds in fallbackWindowBounds {
            if let displayID = displayContainingMost(of: bounds, from: candidates) {
                return displayID
            }
        }
        return nil
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

    private static func integer(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? UInt64, value <= UInt64(Int.max) { return Int(value) }
        return nil
    }
}
