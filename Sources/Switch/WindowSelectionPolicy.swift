import CoreGraphics

/// Pure policy extracted from the CG/AX sweep so Stage Manager's two special
/// cases can be regression-tested without private APIs.
enum StageManagerWindowPolicy {
    static func accepts(bounds: CGRect, title: String, stageManagerEnabled: Bool) -> Bool {
        let hasNormalBounds = bounds.width >= 100 && bounds.height >= 80
        let isVisiblePlaceholder = bounds.width > 0 && bounds.height > 0
        return hasNormalBounds || (stageManagerEnabled && isVisiblePlaceholder && !title.isEmpty)
    }

    static func keepsNoSpaceWindow(
        stageManagerEnabled: Bool,
        currentlyAXBacked: Bool,
        historicallyAXBacked: Bool
    ) -> Bool {
        stageManagerEnabled && (currentlyAXBacked || historicallyAXBacked)
    }
}

/// Determines which enumerated windows belong to the Picker Display's current
/// Space. A window may claim multiple Spaces; minimized/hidden windows retain
/// the older-macOS compatibility behavior, while #99's exact-AX-confirmed Stage
/// Manager windows retain their narrow no-Space exception.
enum PickerSpaceWindowPolicy {
    static func includes(
        claimedSpaceIDs: Set<Int>,
        isMinimized: Bool,
        isHidden: Bool,
        isConfirmedStageManagerOffstage: Bool,
        targetSpaceID: Int,
        windowDisplayID: CGDirectDisplayID? = nil,
        targetDisplayID: CGDirectDisplayID? = nil
    ) -> Bool {
        if claimedSpaceIDs.contains(targetSpaceID) { return true }
        guard claimedSpaceIDs.isEmpty else { return false }
        if isMinimized || isHidden { return true }
        guard isConfirmedStageManagerOffstage else { return false }
        guard let targetDisplayID else { return true }
        return windowDisplayID == targetDisplayID
    }

    /// Conservative degradation when private managed-Space metadata is missing.
    /// Current on-screen windows can still be scoped by Quartz display bounds;
    /// off-screen windows stay out except for the established minimized/hidden
    /// compatibility and exact-AX-confirmed Stage Manager placeholders.
    static func includesWhenSpaceUnknown(
        isInActiveSweep: Bool,
        isMinimized: Bool,
        isHidden: Bool,
        isConfirmedStageManagerOffstage: Bool,
        windowDisplayID: CGDirectDisplayID?,
        targetDisplayID: CGDirectDisplayID
    ) -> Bool {
        if isMinimized || isHidden { return true }
        guard windowDisplayID == targetDisplayID else { return false }
        return isInActiveSweep || isConfirmedStageManagerOffstage
    }
}

/// Keeps focus relocation aligned with the screen/Space captured for this
/// picker invocation instead of consulting a different global active Space.
enum WindowFocusSpacePolicy {
    static func shouldMove(
        claimedSpaceIDs: Set<Int>,
        legacyIsCrossSpace: Bool,
        resolvedDestinationSpaceID: Int?
    ) -> Bool {
        guard let destination = resolvedDestinationSpaceID else {
            return legacyIsCrossSpace
        }
        // Windows visible on either display's current Space are not cross-Space;
        // focusing one should leave it on its own display, not relocate it just
        // because this picker was presented on the other monitor.
        guard legacyIsCrossSpace else { return false }
        guard !claimedSpaceIDs.isEmpty else { return false }
        return !claimedSpaceIDs.contains(destination)
    }
}
