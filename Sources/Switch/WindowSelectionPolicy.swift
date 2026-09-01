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
