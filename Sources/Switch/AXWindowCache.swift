import AppKit
import ApplicationServices

/// Retained AX window elements keyed by CGWindowID.
///
/// Chromium-family apps return an empty kAXWindowsAttribute for windows on
/// other Spaces (their a11y tree only covers on-screen windows), so focusing a
/// fullscreen Chrome window needs an element captured earlier, while the window
/// was still on the active Space. Remote AX references stay valid for the
/// window's lifetime even after it leaves the Space. The prewarm timer keeps
/// this topped up; the query itself also nudges Chromium into enabling its
/// a11y tree.
enum AXWindowCache {
    private static let lock = NSLock()
    private static var cache: [CGWindowID: AXUIElement] = [:]

    static func store(_ element: AXUIElement, for wid: CGWindowID) {
        lock.lock()
        cache[wid] = element
        lock.unlock()
    }

    static func element(for wid: CGWindowID) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return cache[wid]
    }

    /// Historical evidence remains useful while Stage Manager suspends an app's
    /// AX tree (`cannotComplete`), but an explicitly invalid remote element means
    /// the window was closed and must not let a lingering CG shell self-confirm.
    static func hasHistoricalEvidence(for wid: CGWindowID) -> Bool {
        guard let element = element(for: wid) else { return false }
        var role: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        )
        guard status == .invalidUIElement else { return true }

        lock.lock()
        if let current = cache[wid], CFEqual(current, element) {
            cache.removeValue(forKey: wid)
        }
        lock.unlock()
        return false
    }

    /// Drop entries whose windows disappeared from WindowEnumerator's complete
    /// CGWindowList sweep. This keeps the AX history and the enumerator on the
    /// same view of liveness without performing a second, racing sweep.
    static func purge(keeping live: Set<CGWindowID>) {
        lock.lock()
        cache = cache.filter { live.contains($0.key) }
        lock.unlock()
    }
}
