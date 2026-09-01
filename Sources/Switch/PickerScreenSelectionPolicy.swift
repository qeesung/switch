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
