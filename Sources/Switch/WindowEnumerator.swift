import AppKit
import ApplicationServices
import CoreGraphics

enum WindowEnumerator {
    private static let skipApps: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "WallpaperAgent", "Switch",
        "loginwindow", "talagent", "TextInputMenuAgent", "TextInputSwitcher",
        "universalControl", "ControlStrip", "ScreenshotCapture", "WindowManager"
    ]

    private static let helperSuffixes: [String] = [
        "Helper", " Helper", " Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)",
        "Agent", " Agent",
        "Service", " Service", " View Service",
        "Renderer", "(Renderer)",
        "WebContent", "Networking",
        "Extension"
    ]

    private static func isHelperProcess(_ name: String) -> Bool {
        for s in helperSuffixes where name.hasSuffix(s) { return true }
        return false
    }

    struct Enumeration {
        let activeSpace: [WindowInfo]
        let crossSpace: [WindowInfo]
    }

    struct FullSnapshot {
        let activeSpace: [WindowInfo]
        let crossSpace: [WindowInfo]
        let spaceRepresentatives: [WindowInfo]

        var allWindows: [WindowInfo] { activeSpace + crossSpace }
        var allIDs: Set<CGWindowID> { Set(allWindows.map(\.id)) }
        var allPIDs: Set<pid_t> { Set(allWindows.map(\.pid)) }
    }

    private struct CGSweep {
        let windows: [WindowInfo]
        /// Every raw CGWindowID seen before application/window filtering.
        let observedIDs: Set<CGWindowID>
        /// `false` means WindowServer returned no list; callers must not treat
        /// that transient failure as proof that every cached window disappeared.
        let completed: Bool
    }

    // Ghost-confirmation state. Every access takes `ghostLock`; sweeps run on a
    // background queue and noteSwitchMovedWindow is called from the focus path.
    private static let ghostLock = NSLock()
    private static var ghostStrikes: [CGWindowID: (first: Date, count: Int)] = [:]
    private static var switchMovedWindows: [CGWindowID: Date] = [:]
    private static let switchMovedGrace: TimeInterval = 10

    /// Record a window Switch just pulled to the current Space via
    /// CGSMoveWindowsToManagedSpace so the current-space-claim prune skips it: a
    /// failed raise must not strand it as a self-inflicted ghost (v0.3.9 rescue path).
    static func noteSwitchMovedWindow(_ id: CGWindowID) {
        ghostLock.lock()
        switchMovedWindows[id] = Date()
        ghostLock.unlock()
    }

    // True once the current-space-claim ghost is confirmed: count ≥ 2 and ≥ 2.5s
    // since the first strike. Switch-moved wids don't accrue strikes for 10s (#115).
    private static func ghostStrikeConfirmed(_ id: CGWindowID) -> Bool {
        ghostLock.lock()
        defer { ghostLock.unlock() }
        if let moved = switchMovedWindows[id] {
            if Date().timeIntervalSince(moved) < switchMovedGrace { return false }
            switchMovedWindows.removeValue(forKey: id)
        }
        let now = Date()
        if var entry = ghostStrikes[id] {
            entry.count += 1
            ghostStrikes[id] = entry
            return entry.count >= 2 && now.timeIntervalSince(entry.first) >= 2.5
        }
        ghostStrikes[id] = (first: now, count: 1)
        return false
    }

    // The condition no longer holds for this wid → forget its strikes so a dropped
    // window reappears automatically. There is no permanent drop set.
    private static func clearGhostStrike(_ id: CGWindowID) {
        ghostLock.lock()
        ghostStrikes.removeValue(forKey: id)
        ghostLock.unlock()
    }

    // Forget ghost state for windows that are on-screen, AX-backed, or gone.
    private static func housekeepGhostState(onScreen: Set<CGWindowID>, enumerated: Set<CGWindowID>, axBacked: Set<CGWindowID>) {
        ghostLock.lock()
        defer { ghostLock.unlock() }
        for id in ghostStrikes.keys where onScreen.contains(id) || axBacked.contains(id) || !enumerated.contains(id) {
            ghostStrikes.removeValue(forKey: id)
        }
        for id in switchMovedWindows.keys where onScreen.contains(id) || !enumerated.contains(id) {
            switchMovedWindows.removeValue(forKey: id)
        }
    }

    static func fullSnapshot() -> FullSnapshot {
        let stageManager = stageManagerEnabled
        let onScreenSweep = enumerate(
            option: [.optionOnScreenOnly, .excludeDesktopElements],
            stageManager: stageManager
        )
        let everythingSweep = enumerate(
            option: [.optionAll, .excludeDesktopElements],
            stageManager: stageManager
        )
        let onScreen = onScreenSweep.windows
        let everything = everythingSweep.windows
        let observedWindowIDs = onScreenSweep.observedIDs.union(everythingSweep.observedIDs)
        // Purge from the complete CG snapshot before this pass stores fresh AX
        // elements. Doing it afterwards can delete a window created between the
        // CG and AX reads; a failed .optionAll query must never empty the cache.
        if everythingSweep.completed {
            AXWindowCache.purge(keeping: observedWindowIDs)
        }
        let pids = Set(everything.map(\.pid)).union(onScreen.map(\.pid))
        let ax = axWindowState(for: pids, observedWindowIDs: observedWindowIDs)
        let cid = CGSMainConnectionID()
        let metadata = spaceMetadata(cid: cid)
        // Without Screen Recording every CG title is empty, so emptiness is no ghost signal (#106).
        let titlesReliable = CGPreflightScreenCaptureAccess()

        let active = pruneGhosts(onScreen, axBacked: ax.axBacked, cid: cid)
        let activeIDs = Set(active.map(\.id))
        let marked = everything.map { w -> WindowInfo in
            var out = w
            out.isCrossSpace = !activeIDs.contains(w.id)
            return out
        }
        let annotatedAll = annotateAndPrune(marked, ax: ax, cid: cid, metadata: metadata, stageManager: stageManager, titlesReliable: titlesReliable)
        // After annotateAndPrune on purpose: ghost detection keys on the CG title (#111).
        // Active windows need the same per-Space annotation as off-screen
        // windows. With separate Spaces per display, "on screen" spans both
        // displays and is not enough to identify the Picker Display's Space (#129).
        let annotatedByID = Dictionary(uniqueKeysWithValues: annotatedAll.map { ($0.id, $0) })
        let annotatedActive = active.map { annotatedByID[$0.id] ?? $0 }
        let titledActive = backfillTitles(annotatedActive, from: ax.titles)
        let titledAll = backfillTitles(annotatedAll, from: ax.titles)
        let onScreenIDs = Set(onScreen.map(\.id))
        let allEnumeratedIDs = onScreenIDs.union(everything.map(\.id))
        housekeepGhostState(
            onScreen: onScreenIDs,
            enumerated: allEnumeratedIDs,
            axBacked: ax.axBacked
        )
        let cross = titledAll.filter { !activeIDs.contains($0.id) }
        let reps = spaceRepresentatives(from: titledAll, cid: cid, metadata: metadata)
        return FullSnapshot(activeSpace: titledActive, crossSpace: cross, spaceRepresentatives: reps)
    }

    static func enumerate(scope: HotkeyManager.Mode, frontmostPID: pid_t?) -> Enumeration {
        let full = fullSnapshot()
        var active = full.activeSpace
        var cross = full.crossSpace
        if scope == .currentApp, let f = frontmostPID {
            active = active.filter { $0.pid == f }
            cross = cross.filter { $0.pid == f }
        }
        let showCross = (UserDefaults.standard.object(forKey: SwitchPreferences.crossSpaceKey) as? Bool) ?? true
        if !showCross {
            cross = cross.filter { !$0.isCrossSpace }
        }
        return Enumeration(activeSpace: active, crossSpace: cross)
    }

    private static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    private static func appElement(for pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    // AX-backed windows, minimized window IDs, and AX titles for the given processes; an orderedOut leftover appears in neither.
    private static func axWindowState(
        for pids: Set<pid_t>,
        observedWindowIDs: Set<CGWindowID>
    ) -> (axBacked: Set<CGWindowID>, minimized: Set<CGWindowID>, titles: [CGWindowID: String]) {
        var axBacked: Set<CGWindowID> = []
        var minimized: Set<CGWindowID> = []
        var titles: [CGWindowID: String] = [:]
        for pid in pids {
            for ax in AXHelpers.windowList(of: appElement(for: pid)) {
                guard let id = AXHelpers.windowID(of: ax) else { continue }
                // The AX query happens after the complete CG sweep. Do not let
                // an element created (or closing) in that gap seed historical
                // evidence until a CG snapshot has also observed its exact ID.
                guard observedWindowIDs.contains(id) else { continue }
                axBacked.insert(id)
                AXWindowCache.store(ax, for: id)
                let title = AXHelpers.title(of: ax)
                if !title.isEmpty {
                    titles[id] = title
                }
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   let isMin = minRef as? Bool, isMin {
                    minimized.insert(id)
                }
            }
        }
        return (axBacked, minimized, titles)
    }

    private static func backfillTitles(_ windows: [WindowInfo], from titles: [CGWindowID: String]) -> [WindowInfo] {
        windows.map { w in
            guard w.title.isEmpty, let title = titles[w.id] else { return w }
            var out = w
            out.title = title
            return out
        }
    }

    // Drop orphaned on-screen entries: no live AX window and no Space. Real windows always have a Space.
    private static func pruneGhosts(_ windows: [WindowInfo], axBacked: Set<CGWindowID>, cid: CGSConnectionID) -> [WindowInfo] {
        guard !windows.isEmpty else { return windows }
        return windows.filter { w in
            if axBacked.contains(w.id) { return true }
            let arr = [NSNumber(value: w.id)] as CFArray
            let spaces = CGSCopySpacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [Int] ?? []
            return !spaces.isEmpty
        }
    }

    private static func annotateAndPrune(
        _ candidates: [WindowInfo],
        ax: (axBacked: Set<CGWindowID>, minimized: Set<CGWindowID>, titles: [CGWindowID: String]),
        cid: CGSConnectionID,
        metadata: (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>),
        stageManager: Bool,
        titlesReliable: Bool
    ) -> [WindowInfo] {
        return candidates.compactMap { w in
            var out = w
            let arr = [NSNumber(value: w.id)] as CFArray
            let spaces = CGSCopySpacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [Int] ?? []
            if out.isHidden || ax.minimized.contains(w.id) {
                out.isMinimized = ax.minimized.contains(w.id)
                // A window with no Space claim counts as current, older macOS drops the assignment once a window is ordered out (#129).
                out.isCrossSpace = !spaces.isEmpty && !spaces.contains(where: { metadata.currentSpaces.contains($0) })
                // A window AX ever backed is real; the cache outlives per-sweep AX gaps (timeouts, Chromium's off-Space omissions), so a never-backed CG entry is an Electron shell (#126).
                let everBacked = ax.axBacked.contains(w.id)
                    || AXWindowCache.hasHistoricalEvidence(for: w.id)
                // Same real-window signature as the cross-Space prune below, for windows hidden before Switch ever saw them.
                let offSpaceReal = out.isCrossSpace && (!titlesReliable || !w.title.isEmpty)
                guard everBacked || offSpaceReal else { return nil }
                if let sid = spaces.first {
                    let info = metadata.labels[sid]
                    out.spaceID = sid
                    out.spaceLabel = info?.label
                    out.isFullscreenSpace = info?.isFullscreen ?? false
                }
                out.spaceIDs = Set(spaces)
                return out
            }
            if spaces.isEmpty {
                // A real off-stage window can lose both its Space assignment and
                // its current AX tree. The shared AX cache supplies exact-ID
                // historical evidence without adding a second lifecycle cache.
                guard StageManagerWindowPolicy.keepsNoSpaceWindow(
                    stageManagerEnabled: stageManager,
                    currentlyAXBacked: ax.axBacked.contains(w.id),
                    historicallyAXBacked: AXWindowCache.hasHistoricalEvidence(for: w.id)
                ) else { return nil }
                out.isCrossSpace = false
                out.isStageManagerOffstage = true
                return out
            }
            if !ax.axBacked.contains(w.id) {
                // Every Space it claims has been deleted → can't be a real window
                // (real windows always sit on a live Space). Stateless, self-heals.
                if !spaces.contains(where: { metadata.labels[$0] != nil }) {
                    clearGhostStrike(w.id)
                    return nil
                }
                // orderOut'd shell signatures, confirmed across two strikes ≥2.5s apart
                // so a real window caught mid Space-transition survives (transitions
                // settle in <1s; Current Space races ahead of CGWindowList and Chromium
                // exposes no AX in that gap): claims the current Space, or has an empty
                // CG title; real cross-Space windows always carry one (browser windows
                // have a page title), so an untitled shell on any live Space is a ghost.
                let currentClaim = spaces.contains(where: { metadata.currentSpaces.contains($0) })
                if out.isCrossSpace && (currentClaim || (titlesReliable && out.title.isEmpty)) {
                    if ghostStrikeConfirmed(w.id) { return nil }
                } else {
                    clearGhostStrike(w.id)
                }
            }
            if let sid = spaces.first {
                let info = metadata.labels[sid]
                out.spaceID = sid
                out.spaceLabel = info?.label
                out.isFullscreenSpace = info?.isFullscreen ?? false
            }
            out.spaceIDs = Set(spaces)
            return out
        }
    }

    private static func spaceRepresentatives(
        from annotated: [WindowInfo],
        cid: CGSConnectionID,
        metadata: (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>)
    ) -> [WindowInfo] {
        let active = Int(CGSGetActiveSpace(cid))
        let grouped = Dictionary(grouping: annotated) { $0.spaceID ?? -1 }
        return metadata.order.compactMap { sid in
            guard sid != -1, let windows = grouped[sid], !windows.isEmpty else { return nil }
            let sorted = WindowMRU.sorted(windows, frontmost: nil)
            guard let target = sorted.first else { return nil }
            let apps = Array(NSOrderedSet(array: sorted.map(\.appName)).compactMap { $0 as? String }).prefix(3)
            let suffix = String(localized: "\(sorted.count) windows", comment: "Space tile: window count")
            let detail = apps.isEmpty ? suffix : "\(suffix) · \(apps.joined(separator: ", "))"
            let info = metadata.labels[sid]
            return WindowInfo(
                id: target.id,
                pid: target.pid,
                appName: info?.label ?? String(localized: "Desktop", comment: "Fallback Space name"),
                bounds: target.bounds,
                title: detail,
                displayID: target.displayID,
                spaceID: sid,
                spaceIDs: [sid],
                isCrossSpace: sid != active,
                isMinimized: false,
                isHidden: false,
                spaceLabel: sid == active ? "Current" : nil,
                isFullscreenSpace: info?.isFullscreen ?? false,
                isWindowless: false,
                bundleID: target.bundleID
            )
        }
    }

    /// Builds a `spaceID → "Desktop N" / "Fullscreen"` map by walking CGS's managed-display spaces in order.
    private static func spaceMetadata(cid: CGSConnectionID) -> (labels: [Int: (label: String, isFullscreen: Bool)], order: [Int], currentSpaces: Set<Int>) {
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return ([:], [], []) }
        var labels: [Int: (label: String, isFullscreen: Bool)] = [:]
        var order: [Int] = []
        var currentSpaces: Set<Int> = []
        var desktop = 0
        for display in displays {
            if let current = display["Current Space"] as? [String: Any], let id = current["id64"] as? Int {
                currentSpaces.insert(id)
            }
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let id = space["id64"] as? Int else { continue }
                order.append(id)
                let type = space["type"] as? Int ?? 0
                if type == 0 {
                    desktop += 1
                    labels[id] = (String(localized: "Desktop \(desktop)", comment: "Mission Control Space name"), false)
                } else {
                    labels[id] = (String(localized: "Fullscreen", comment: "Fullscreen Space name"), true)
                }
            }
        }
        return (labels, order, currentSpaces)
    }

    private static func enumerate(option: CGWindowListOption, stageManager: Bool) -> CGSweep {
        guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return CGSweep(windows: [], observedIDs: [], completed: false)
        }
        let observedIDs = Set(raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let displayBounds = activeDisplayBounds()
        let blacklist = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.blacklistKey) ?? [])
        var blockedPIDs: Set<pid_t> = []
        if !blacklist.isEmpty {
            for app in NSWorkspace.shared.runningApplications {
                if let bid = app.bundleIdentifier, blacklist.contains(bid) {
                    blockedPIDs.insert(app.processIdentifier)
                }
            }
        }
        var out: [WindowInfo] = []
        var seenIDs: Set<CGWindowID> = []
        let titlesReliable = CGPreflightScreenCaptureAccess()
        for d in raw {
            let appName = d[kCGWindowOwnerName as String] as? String ?? ""
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = d[kCGWindowAlpha as String] as? Double else { continue }
            guard let id = d[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let pid = d[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if skipApps.contains(appName) { continue }
            if isHelperProcess(appName) { continue }
            if blockedPIDs.contains(pid) { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            if app == nil || app?.activationPolicy != .regular { continue }
            if alpha <= 0 && app?.isHidden != true { continue }
            let title = d[kCGWindowName as String] as? String ?? ""
            let boundsDict = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            // WindowServer can report tiny placeholder bounds for real off-stage
            // windows. Only titled, layer-zero windows from regular apps reach
            // this point, so keep that narrow Stage Manager exception (#99).
            if !StageManagerWindowPolicy.accepts(
                bounds: bounds,
                title: title,
                stageManagerEnabled: stageManager
            ) { continue }
            if title.isEmpty && titlesReliable
                && (bounds.width < 400 || bounds.height < 300) { continue }
            // Dedupe by CGWindowID only; it's already unique per window.
            // The earlier (pid, title, bounds) dedupe was collapsing multiple
            // Chrome windows that shared the same active-tab title.
            if seenIDs.contains(id) { continue }
            seenIDs.insert(id)
            out.append(WindowInfo(
                id: id,
                pid: pid,
                appName: appName,
                bounds: bounds,
                title: title,
                displayID: displayContainingMost(of: bounds, candidates: displayBounds),
                isHidden: app?.isHidden == true,
                bundleID: app?.bundleIdentifier
            ))
        }
        return CGSweep(windows: out, observedIDs: observedIDs, completed: true)
    }

    private static func activeDisplayBounds() -> [(CGDirectDisplayID, CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
    }

    private static func displayContainingMost(
        of bounds: CGRect,
        candidates: [(CGDirectDisplayID, CGRect)]
    ) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for (displayID, displayBounds) in candidates {
            let intersection = bounds.intersection(displayBounds)
            let area: CGFloat = intersection.isNull ? 0 : intersection.width * intersection.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area {
                best = (displayID, area)
            }
        }
        return best?.id
    }
}
