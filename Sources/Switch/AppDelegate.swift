import AppKit
import Combine
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

extension Notification.Name {
    static let switchCheckForUpdates = Notification.Name("switch.checkForUpdates")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Under the SwiftUI lifecycle NSApp.delegate is SwiftUI's own wrapper, so casting it to AppDelegate finds nothing (#127).
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    #if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )
    var sparkleUpdater: SPUUpdater? { updaterController.updater }
    #endif
    private var model: SwitchModel?
    private var hotkey: HotkeyManager?
    private var window: SwitcherWindow?
    private var statusBar: StatusBarController?
    private var onboardingModel: OnboardingModel?
    private var onboardingWindow: NSWindow?
    private var focusTracker: FocusTracker?
    private var hotkeyStarted = false
    private var focusTrackerStarted = false
    #if DEBUG
    private let debugHarness = DebugFocusHarness()
    #endif
    private var permsTimer: Timer?
    private var armedWatchdog: Timer?
    private var clickAwayMonitor: Any?
    private var pendingPresent: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        #if DEBUG
        debugHarness.start()
        #endif

        let model = SwitchModel()
        let window = SwitcherWindow(model: model)
        let hotkey = HotkeyManager()
        // @Published emits in willSet, before the preference didSet persists to
        // UserDefaults. Size on the next main-loop turn so calculations observe
        // the new value rather than lagging one change behind.
        let resizePicker: () -> Void = { [weak model, weak window] in
            DispatchQueue.main.async {
                window?.applyContentSize(for: model?.pickerScreenResolution?.screen)
            }
        }

        // Most tap callbacks force a pending picker onto screen before acting.
        let present: () -> Void = { [weak self] in self?.presentNowIfPending(window: window) }

        hotkey.onArm = { [weak self] style in
            // Resolve Mouse / Active / Primary exactly once per invocation.
            // Window filtering and panel placement both consume this result (#129).
            let pickerScreen = PickerScreenResolver.resolve(
                SwitchPreferences.shared.pickerDisplay
            )
            model.arm(style, pickerScreenResolution: pickerScreen)
            self?.schedulePresent(window: window)
        }
        hotkey.onAdvance = { reverse in
            present()
            model.advance(reverse: reverse)
        }
        // Gate new picker shortcuts until the old key panel has been ordered out.
        hotkey.onCommit = { [weak self, weak model, weak window] in
            self?.hotkey?.beginDismissal()
            self?.cancelPendingPresent()
            window?.dismiss()
            let target = model?.commit()
            self?.hotkey?.finishDismissal(afterFocusing: target)
        }
        model.commitAndDismiss = { [weak self, weak model, weak window] in
            self?.hotkey?.beginDismissal()
            self?.cancelPendingPresent()
            window?.dismiss()
            let target = model?.commit()
            self?.hotkey?.finishDismissal(afterFocusing: target)
        }
        hotkey.onCancel = { [weak self, weak model, weak window] in
            self?.hotkey?.beginDismissal()
            self?.cancelPendingPresent()
            window?.dismiss()
            model?.cancel()
            self?.hotkey?.finishDismissal()
        }
        let cancelAndDismiss: () -> Void = { [weak self, weak model, weak window] in
            self?.hotkey?.beginDismissal()
            self?.cancelPendingPresent()
            window?.dismiss()
            model?.cancel()
            self?.hotkey?.finishDismissal()
        }
        model.cancelAndDismiss = cancelAndDismiss
        model.onMetricsChange = { [weak window] in window?.applyContentSize() }
        model.contentDidChange = { [weak model, weak window] in
            window?.applyContentSize(for: model?.pickerScreenResolution?.screen)
        }
        hotkey.onCloseSelected = { present(); model.closeSelected() }
        hotkey.onCloseSelectedApp = { present(); model.closeSelectedApp() }
        hotkey.onHideSelected = { present(); model.hideSelected() }
        hotkey.onNavigate = { present(); model.navigate(direction: $0) }
        hotkey.onPickIndex = { present(); model.pickIndex($0) }
        hotkey.onPickSelectOnly = { present(); model.selectIndex($0) }
        hotkey.onFilterAppend = { present(); model.appendFilter($0) }
        hotkey.onFilterBackspace = { present(); model.backspaceFilter() }
        hotkey.onStickyToggle = {
            SwitchPreferences.shared.stickyMode.toggle()
        }
        hotkey.onOpenSettings = {
            MainActor.assumeIsolated { SettingsWindow.shared.show() }
        }

        SwitchPreferences.shared.$verticalList
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$pickerSize
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$thumbnailHeight
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$appIconSize
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$gridColumns
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$maxListRows
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$listWidth
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$showHintStrip
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$verticalShowPreview
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$verticalShowHeader
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        model.$filterHeaderVisible
            .removeDuplicates()
            .dropFirst()
            .sink { _ in resizePicker() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$showThumbnails
            .dropFirst()
            .sink { [weak self] enabled in
                resizePicker()
                if enabled && CGPreflightScreenCaptureAccess() == false {
                    self?.showOnboarding()
                } else if self?.requiredPermissionsGranted == true {
                    self?.startHotkeyIfNeeded()
                    self?.startFocusTrackerIfNeeded()
                }
            }
            .store(in: &cancellables)
        SwitchPreferences.shared.$hideMenuBarIcon
            .dropFirst()
            .sink { [weak self] hidden in
                self?.statusBar?.setHidden(hidden)
            }
            .store(in: &cancellables)

        self.model = model
        self.hotkey = hotkey
        self.window = window
        self.statusBar = StatusBarController()
        self.onboardingModel = OnboardingModel()
        self.focusTracker = FocusTracker()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCheckForUpdates),
            name: .switchCheckForUpdates, object: nil
        )
        #if canImport(Sparkle)
        _ = updaterController
        #endif
        NotificationCenter.default.addObserver(
            forName: HotkeyConfig.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkey?.reload()
        }

        // Show onboarding if any permission is missing; otherwise install the tap.
        if !requiredPermissionsGranted {
            showOnboarding()
        } else {
            startHotkeyIfNeeded()
            startFocusTrackerIfNeeded()
        }

        // Background poll: as soon as both are granted, install the tap.
        permsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.requiredPermissionsGranted {
                self.startHotkeyIfNeeded()
                self.startFocusTrackerIfNeeded()
            }
        }

        // Watchdog: armed with no panel visible and none pending means the tap
        // is consuming keystrokes for a picker that doesn't exist (the "keyboard
        // stops working until Switch quits" report). Clear it.
        armedWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hotkey = self.hotkey, let model = self.model else { return }
                guard hotkey.isArmed else { return }
                if !model.visible && self.pendingPresent == nil {
                    hotkey.clearArmed()
                } else if model.visible {
                    hotkey.recoverIfReleaseWasMissed()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .switchRecorderBegan, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model?.visible == true { cancelAndDismiss() }
                self?.hotkey?.setSuspended(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .switchRecorderEnded, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkey?.setSuspended(false)
        }

        // A click in another app while the picker floats (sticky mode) should
        // dismiss it; otherwise the panel lingers and the tap keeps eating keys.
        // Global monitors never see events routed to our own panel.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.visible == true else { return }
                cancelAndDismiss()
            }
        }
    }

    // Relaunching while already running reopens Settings and restores the menu bar icon if it was dragged off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.setHidden(UserDefaults.standard.bool(forKey: SwitchPreferences.hideMenuBarIconKey))
        if requiredPermissionsGranted {
            SettingsWindow.shared.show()
        } else {
            showOnboarding()
        }
        return true
    }

    private var requiredPermissionsGranted: Bool {
        let thumbnailsEnabled = (UserDefaults.standard.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let screenCaptureOK = !thumbnailsEnabled || CGPreflightScreenCaptureAccess()
        return AXIsProcessTrusted() && screenCaptureOK
    }

    private func schedulePresent(window: SwitcherWindow) {
        pendingPresent?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            self?.pendingPresent = nil
            window?.present()
        }
        pendingPresent = work
        let ms = (UserDefaults.standard.object(forKey: SwitchPreferences.pickerActivationDelayKey) as? Double) ?? SwitchPreferences.defaultPickerActivationDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000.0, execute: work)
    }

    private func presentNowIfPending(window: SwitcherWindow) {
        guard let pending = pendingPresent else { return }
        pending.cancel()
        pendingPresent = nil
        window.present()
    }

    private func cancelPendingPresent() {
        pendingPresent?.cancel()
        pendingPresent = nil
    }

    private func startHotkeyIfNeeded() {
        guard !hotkeyStarted else { return }
        hotkey?.start()
        hotkeyStarted = true
        WindowStore.shared.refresh()
        MainActor.assumeIsolated { model?.startPrewarm() }
    }

    private func startFocusTrackerIfNeeded() {
        guard !focusTrackerStarted else { return }
        focusTracker?.start()
        focusTrackerStarted = true
    }

    @objc private func handleCheckForUpdates() {
        #if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
        #else
        let alert = NSAlert()
        alert.messageText = String(localized: "Updates not configured", comment: "Alert when Sparkle is missing")
        alert.informativeText = String(localized: "This build doesn't include Sparkle. Visit switch-dev.sanyamgarg.com to download the latest.", comment: "Alert body when Sparkle is missing")
        alert.runModal()
        #endif
    }

    private func showOnboarding() {
        guard let onboardingModel else { return }
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView().environmentObject(onboardingModel))
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = String(localized: "Switch", comment: "Brand name; do not translate")
            win.contentViewController = host
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            onboardingWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == onboardingWindow else { return }
        onboardingModel?.stopPolling()
        onboardingWindow = nil
        let settingsOpen = MainActor.assumeIsolated { SettingsWindow.shared.isVisible }
        if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

#if canImport(Sparkle)
extension AppDelegate: SPUStandardUserDriverDelegate {
    // An accessory app's windows are invisible to app switchers; go regular while Sparkle's update UI is up.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        let settingsOpen = MainActor.assumeIsolated { SettingsWindow.shared.isVisible }
        if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
#endif

final class SwitcherWindow: NSPanel {
    private let model: SwitchModel
    private var sizingSession = PanelSizingSession()

    init(model: SwitchModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let host = NSHostingView(rootView: SwitchView().environmentObject(model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        applyContentSize()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseUp, event.buttonNumber == 2, model.visible,
           model.mode != .spaces,
           !UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey),
           let wid = model.pointerWindowID {
            model.closeWindow(withWindowID: wid)
            return
        }
        super.sendEvent(event)
    }

    func applyContentSize(for screen: NSScreen? = nil) {
        let targetScreen = screen
            ?? model.pickerScreenResolution?.screen
            ?? self.screen
            ?? NSScreen.main
        let itemCount = sizingSession.itemCount(
            unfilteredCount: model.windows.count,
            isFiltering: !model.filterText.isEmpty
        )
        let fitted = SwitcherPanelSize.current(
            mode: model.mode,
            itemCount: itemCount,
            metrics: model.metrics,
            filterHeader: model.filterHeaderVisible,
            screen: targetScreen
        )
        model.panelSize = CGSize(width: fitted.width, height: fitted.height)
        setContentSize(fitted)
        if isVisible, let targetScreen {
            center(on: targetScreen)
        }
    }

    func present() {
        // Re-asserted every present so the panel migrates across Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = SwitchPreferences.shared.disableAnimations ? .none : .default

        // Captured when this invocation armed, before the activation delay. Do
        // not independently re-resolve Picker Display here: a moved mouse or a
        // key-window change must not make placement disagree with filtering.
        let screen = model.pickerScreenResolution?.screen ?? NSScreen.main
        applyContentSize(for: screen)
        if let screen {
            center(on: screen)
        }
        orderFrontRegardless()
    }

    private func center(on screen: NSScreen) {
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }

    func dismiss() {
        orderOut(nil)
    }
}

private enum SwitcherPanelSize {
    static func current(
        mode: HotkeyManager.Mode,
        itemCount: Int,
        metrics: PanelMetrics,
        filterHeader: Bool,
        screen: NSScreen?
    ) -> NSSize {
        let defaults = UserDefaults.standard
        let isList = defaults.bool(forKey: SwitchPreferences.verticalListKey)
        let pickerSize = PickerSizeChoice(
            rawValue: defaults.string(forKey: SwitchPreferences.pickerSizeKey) ?? ""
        ) ?? .large
        let scale = pickerSize.scale
        let thumbnailHeight = (defaults.object(
            forKey: SwitchPreferences.thumbnailHeightKey
        ) as? Double) ?? SwitchPreferences.defaultThumbnailHeight
        let gridScale = CGFloat(SwitchPreferenceRules.gridScale(
            pickerScale: Double(scale),
            thumbnailHeight: thumbnailHeight
        ))
        let count = max(itemCount, 1)
        // Keep this in lockstep with SwitchView.showHeader. A filter can reveal a
        // preference-hidden header and must budget its height instead of stealing it
        // from the final complete row.
        let showsHeader = mode == .spaces || !isList || filterHeader
            || ((defaults.object(forKey: SwitchPreferences.verticalShowHeaderKey) as? Bool) ?? true)
        // Lists still fit whole rows to their content. Grids intentionally keep a
        // preset-sized frame so filtering can enlarge cards without moving the panel.
        if mode == .spaces || isList {
            return listSize(
                defaults: defaults,
                count: count,
                showsHeader: showsHeader,
                metrics: metrics,
                scale: scale,
                screen: screen
            )
        }
        return gridSize(
            defaults: defaults,
            count: count,
            scale: gridScale,
            screen: screen
        )
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    // Mirrors the scaled hint strip and list-row geometry in SwitchView.
    private static func hintStripHeight(scale: CGFloat) -> CGFloat {
        let label = lineHeight(.systemFont(ofSize: 11 * scale))
        let key = lineHeight(.monospacedSystemFont(ofSize: 10 * scale, weight: .semibold))
            + 2 * scale
        return max(label, key) + 16 * scale
    }

    private static func listRowHeight(
        iconSize: CGFloat,
        showPreview: Bool,
        scale: CGFloat
    ) -> CGFloat {
        let textHeight = lineHeight(.systemFont(ofSize: 14 * scale, weight: .semibold))
            + 2 * scale
            + lineHeight(.systemFont(ofSize: 12 * scale))
        var content = max(iconSize, textHeight)
        if showPreview { content = max(content, 50 * scale) }
        return content + 12 * scale
    }

    private static func measured(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value > 0 ? value : fallback
    }

    private static func listSize(
        defaults: UserDefaults,
        count: Int,
        showsHeader: Bool,
        metrics: PanelMetrics,
        scale: CGFloat,
        screen: NSScreen?
    ) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let showThumbs = (defaults.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let showPreview = ((defaults.object(forKey: SwitchPreferences.verticalShowPreviewKey) as? Bool) ?? true) && showThumbs
        let iconSize = CGFloat(
            (defaults.object(forKey: SwitchPreferences.appIconSizeKey) as? Double)
                ?? SwitchPreferences.defaultAppIconSize
        ) * scale
        let hintHeight = showHints
            ? measured(metrics.hintHeight, fallback: hintStripHeight(scale: scale))
            : 0
        let rowHeight = measured(
            metrics.rowHeight,
            fallback: listRowHeight(iconSize: iconSize, showPreview: showPreview, scale: scale)
        )
        // The measured header includes its 10pt top padding; the initial fallback does too.
        let headerHeight = showsHeader ? measured(metrics.headerHeight, fallback: 44 * scale) : 0
        let maxRows = SwitchPreferenceRules.clampedMaxListRows(
            (defaults.object(forKey: SwitchPreferences.maxListRowsKey) as? Int)
                ?? SwitchPreferences.defaultMaxListRows
        )
        let listWidth = SwitchPreferenceRules.resolvedListWidth(
            storedListWidth: defaults.object(forKey: SwitchPreferences.listWidthKey) as? Double,
            legacyThumbnailHeight: defaults.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double
        ) * Double(scale)
        let result = SwitcherPanelLayout.list(
            width: CGFloat(listWidth),
            itemCount: count,
            maxRows: maxRows,
            rowHeight: rowHeight,
            headerHeight: headerHeight,
            hintHeight: hintHeight,
            showsHeader: showsHeader,
            heightLimit: screen.map { $0.visibleFrame.height * SwitcherPanelLayout.screenFraction },
            visualScale: scale
        )
        return NSSize(
            width: fittedWidth(result.size.width, on: screen),
            height: result.size.height
        )
    }

    private static func gridSize(
        defaults: UserDefaults,
        count: Int,
        scale: CGFloat,
        screen: NSScreen?
    ) -> NSSize {
        let configuredColumns = (defaults.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? SwitchPreferences.defaultGridColumns
        let targetWidth = max(560, 880 * scale)
        let targetHeight = max(320, 560 * scale)
        let result = SwitcherPanelLayout.grid(
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            itemCount: count,
            configuredColumns: configuredColumns,
            widthLimit: screen.map { $0.visibleFrame.width * SwitcherPanelLayout.screenFraction },
            heightLimit: screen.map { $0.visibleFrame.height * SwitcherPanelLayout.screenFraction }
        )
        return result.size
    }

    private static func fittedWidth(_ width: CGFloat, on screen: NSScreen?) -> CGFloat {
        guard let screen else { return width }
        return min(width, screen.visibleFrame.width * SwitcherPanelLayout.screenFraction)
    }
}
