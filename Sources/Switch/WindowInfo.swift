import CoreGraphics
import Foundation

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bounds: CGRect
    var title: String
    /// Display whose Quartz bounds overlap this window most. This remains
    /// available when Stage Manager temporarily drops the Space claim.
    var displayID: CGDirectDisplayID? = nil
    var spaceID: Int?
    var spaceIDs: Set<Int> = []
    var isCrossSpace: Bool = false
    var isMinimized: Bool = false
    var isHidden: Bool = false
    /// Space-less Stage Manager window retained only after an exact current or
    /// historical AXWindowCache ID match (#99).
    var isStageManagerOffstage = false
    var spaceLabel: String?
    var isFullscreenSpace: Bool = false
    var isWindowless: Bool = false
    var bundleID: String?
}
