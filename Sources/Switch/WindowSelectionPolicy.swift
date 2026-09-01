import CoreGraphics

/// Pure policy extracted from the CG/AX sweep so Stage Manager's two special
/// cases can be regression-tested without private APIs.
enum StageManagerWindowPolicy {
    static func accepts(bounds: CGRect, title: String, stageManagerEnabled: Bool) -> Bool {
        let hasNormalBounds = bounds.width >= 100 && bounds.height >= 80
        return hasNormalBounds || (stageManagerEnabled && !title.isEmpty)
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
        targetSpaceID: Int
    ) -> Bool {
        if claimedSpaceIDs.contains(targetSpaceID) { return true }
        guard claimedSpaceIDs.isEmpty else { return false }
        return isMinimized || isHidden || isConfirmedStageManagerOffstage
    }
}
