import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

final class HotkeyManager {
    typealias Mode = PickerMode
    enum Direction { case left, right, up, down }

    /// How a binding arms the picker: base mode plus per-binding overrides (#131, #130).
    struct ArmStyle {
        let mode: Mode
        var sticky = false
        var currentSpaceOnly = false
        /// Shift held at arm: start from the least-recent window, like native ⌘⇧Tab (#144).
        var reverse = false
    }

    private struct BufferedKeyDown {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let isRepeat: Bool
    }

    private static let armSlots: [(slot: HotkeyConfig.Slot, style: ArmStyle)] = [
        (.allWindows, ArmStyle(mode: .allWindows)),
        (.allWindowsAlternate, ArmStyle(mode: .allWindows)),
        (.spaces, ArmStyle(mode: .spaces)),
        (.spacesAlternate, ArmStyle(mode: .spaces)),
        (.currentApp, ArmStyle(mode: .currentApp)),
        (.currentAppAlternate, ArmStyle(mode: .currentApp)),
        (.allWindowsSticky, ArmStyle(mode: .allWindows, sticky: true)),
        (.currentAppSticky, ArmStyle(mode: .currentApp, sticky: true)),
        (.currentSpace, ArmStyle(mode: .allWindows, currentSpaceOnly: true))
    ]

    var onArm: ((ArmStyle) -> Void)?
    var onAdvance: ((Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCloseSelected: (() -> Void)?
    var onCloseSelectedApp: (() -> Void)?
    var onHideSelected: (() -> Void)?
    var onNavigate: ((Direction) -> Void)?
    var onPickIndex: ((Int) -> Void)?
    var onPickSelectOnly: ((Int) -> Void)?
    var onFilterAppend: ((Character) -> Void)?
    var onFilterBackspace: (() -> Void)?
    var onSearchEditingCommand: ((PickerInputRoutingPolicy.SearchEditingCommand) -> Void)?
    var onStickyToggle: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armed: Mode?
    private var armedBinding: HotkeyBinding?
    private var armedSticky = false
    private var armedCurrentSpaceOnly = false
    private var armedSequence: UInt64 = 0
    private var lastShift = false
    private var shiftTapPending = false
    private var searchFieldFocused = false
    private var stickyModifiersReleased = false
    private var dismissalPending = false
    private var dismissalGeneration: UInt64 = 0
    private var bufferedKeyDowns: [BufferedKeyDown] = []
    private var replayInFlightGeneration: UInt64?
    private var suspended = false
    private var stopRequested = false

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapReady = DispatchSemaphore(value: 0)

    private var wakeToken: NSObjectProtocol?
    private var screensWakeToken: NSObjectProtocol?
    private var inputSourceToken: NSObjectProtocol?
    private var healthTimer: Timer?

    private static let kcEscape: CGKeyCode = 53
    private static let kcReturn: CGKeyCode = 36
    private static let kcKeypadEnter: CGKeyCode = 76
    private static let kcDelete: CGKeyCode = 51
    private static let kcLeftArrow: CGKeyCode = 123
    private static let kcRightArrow: CGKeyCode = 124
    private static let kcDownArrow: CGKeyCode = 125
    private static let kcUpArrow: CGKeyCode = 126
    /// A marker key with no normal text meaning. Ordered native picker commands
    /// are rewritten to this key until SwitcherWindow consumes their user data.
    private static let kcOrderedPickerMarker: CGKeyCode = 90 // F20

    func start() {
        if !ensureAccessibility() { return }
        KeyboardLayoutTranslator.shared.refresh()
        startTapThread()
        installWakeObserver()
        installInputSourceObserver()
        startHealthCheck()
    }

    func stop() {
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
        if let screensWakeToken { NSWorkspace.shared.notificationCenter.removeObserver(screensWakeToken) }
        if let inputSourceToken { DistributedNotificationCenter.default().removeObserver(inputSourceToken) }
        wakeToken = nil
        screensWakeToken = nil
        inputSourceToken = nil
        healthTimer?.invalidate()
        healthTimer = nil
        stateLock.lock()
        stopRequested = true
        stateLock.unlock()
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        tapThread = nil
        stateLock.lock()
        tapRunLoop = nil
        stateLock.unlock()
    }

    private func startTapThread() {
        guard tapThread == nil else { return }
        stateLock.lock()
        stopRequested = false
        stateLock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.stateLock.unlock()
            self.installTap()
            self.tapReady.signal()
            while true {
                self.stateLock.lock()
                let shouldStop = self.stopRequested
                self.stateLock.unlock()
                if shouldStop { break }
                let result = CFRunLoopRunInMode(.defaultMode, 3600, false)
                if result == .finished { Thread.sleep(forTimeInterval: 1.0) }
            }
        }
        thread.name = "com.sanyamgarg.switch.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        _ = tapReady.wait(timeout: .now() + 1.0)
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        stateLock.lock()
        let rl = tapRunLoop
        stateLock.unlock()
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func uninstallTap() {
        stateLock.lock()
        let tap = self.tap
        let source = self.source
        self.tap = nil
        self.source = nil
        stateLock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
    }

    /// Sleep/wake + screensaver-end can leave the tap in a disabled state that
    /// `tapDisabledByTimeout` doesn't always cover. Listen explicitly and
    /// reinstall.
    private func installWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        wakeToken = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
        screensWakeToken = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
    }

    private func installInputSourceObserver() {
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceToken = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                KeyboardLayoutTranslator.shared.refresh()
            }
        }
    }

    /// Defense in depth: even with timeout + wake handlers, occasionally a tap
    /// ends up disabled (TCC blip, run-loop weirdness). Cheap to check.
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
    }

    private func reinstallIfNeeded() {
        stateLock.lock()
        let tap = self.tap
        stateLock.unlock()
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            self?.installTap()
        }
    }

    @discardableResult
    private func ensureAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return mgr.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: cb,
            userInfo: info
        ) else {
            NSLog("Switch: failed to create event tap")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        stateLock.lock()
        self.tap = tap
        self.source = src
        stateLock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = self.tap
            stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        if let sentinelGeneration = PickerInputRoutingPolicy.replaySentinelGeneration(
            from: sourceUserData
        ) {
            handleReplaySentinel(generation: sentinelGeneration)
            return nil
        }
        let replayGeneration = PickerInputRoutingPolicy.replayedKeyEventGeneration(
            from: sourceUserData
        )
        if replayGeneration != nil {
            // Let the replayed key take the normal hotkey path exactly once.
            event.setIntegerValueField(.eventSourceUserData, value: 0)
        }
        stateLock.lock()
        let isSuspended = suspended
        let replayBelongsToCurrentFence = replayGeneration == dismissalGeneration
        if !isSuspended, dismissalPending, type == .keyDown,
           replayGeneration == nil || !replayBelongsToCurrentFence {
            bufferedKeyDowns.append(BufferedKeyDown(
                keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            ))
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        if isSuspended { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            let typeToFilter = (UserDefaults.standard.object(
                forKey: SwitchPreferences.typeToFilterKey
            ) as? Bool) ?? true
            stateLock.lock()
            // Any key while Shift is down makes it a chord (⇧⌘W), not a reverse tap (#143).
            shiftTapPending = false
            let nativeEditingBeforeHotkey = typeToFilter
                && PickerInputRoutingPolicy.nativeEditingAvailable(
                    searchFieldFocused: searchFieldFocused,
                    stickySession: armedSticky,
                    stickyModifiersReleased: stickyModifiersReleased
                )
            stateLock.unlock()

            if let stickyBinding = HotkeyConfig.shared[.stickyToggle],
               stickyBinding.matchesTrigger(keyCode: kc, flags: flags) {
                if nativeEditingBeforeHotkey {
                    beginInputFence()
                    return orderedPickerEvent(
                        event,
                        kind: .hotkey,
                        originalKeyCode: kc,
                        originalFlags: flags
                    )
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onStickyToggle?()
                }
                return nil
            }

            for (slot, style) in Self.armSlots {
                guard let binding = HotkeyConfig.shared[slot],
                      binding.matchesTrigger(keyCode: kc, flags: flags) else { continue }
                if nativeEditingBeforeHotkey {
                    beginInputFence()
                    return orderedPickerEvent(
                        event,
                        kind: .hotkey,
                        originalKeyCode: kc,
                        originalFlags: flags
                    )
                }
                armOrAdvance(style, binding: binding, shift: shift)
                if replayGeneration != nil {
                    // Replayed keyDowns have no matching hardware flagsChanged.
                    // Recover from the current physical flags immediately so a
                    // hold-style picker does not linger until the watchdog.
                    recoverIfReleaseWasMissed()
                }
                return nil
            }

            stateLock.lock()
            if armedSticky, let armedBinding {
                // Recover a missed flagsChanged release as soon as a later key
                // proves the invocation modifiers are no longer down.
                stickyModifiersReleased = PickerInputRoutingPolicy.updatedStickyModifiersReleased(
                    stickyModifiersReleased,
                    hotkeyMatched: false,
                    required: armedBinding.cgFlags,
                    current: flags
                )
            }
            let armedMode = armed
            let activeBinding = armedBinding
            let sticky = armedSticky
            let focusedSearchField = searchFieldFocused
            let stickyWasReleased = stickyModifiersReleased
            stateLock.unlock()

            if armedMode != nil {
                let actionModifierMatches = cmd && (sticky || !typeToFilter || shift)
                let nativeEditing = typeToFilter && PickerInputRoutingPolicy.nativeEditingAvailable(
                    searchFieldFocused: focusedSearchField,
                    stickySession: sticky,
                    stickyModifiersReleased: stickyWasReleased
                )
                if kc == Self.kcEscape {
                    if nativeEditing {
                        beginInputFence()
                        return orderedPickerEvent(
                            event,
                            kind: .terminal,
                            originalKeyCode: kc,
                            originalFlags: flags
                        )
                    }
                    let generation = beginDismissal()
                    dispatchIfFenceCurrent(generation: generation) { [weak self] in
                        self?.onCancel?()
                    }
                    return nil
                }
                if kc == Self.kcReturn || kc == Self.kcKeypadEnter {
                    if nativeEditing {
                        beginInputFence()
                        return orderedPickerEvent(
                            event,
                            kind: .terminal,
                            originalKeyCode: kc,
                            originalFlags: flags
                        )
                    }
                    let generation = beginDismissal()
                    dispatchIfFenceCurrent(generation: generation) { [weak self] in
                        self?.onCommit?()
                    }
                    return nil
                }
                if !sticky && !(activeBinding?.modifiersHeld(flags) ?? false) {
                    let generation = beginDismissal()
                    // This keyDown is itself the evidence that a flagsChanged
                    // release was missed. It arrived before focus transfer, so
                    // buffer it with later keys instead of leaking it to the app
                    // that was active before the picker.
                    stateLock.lock()
                    bufferedKeyDowns.append(BufferedKeyDown(
                        keyCode: kc,
                        flags: flags,
                        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    ))
                    stateLock.unlock()
                    dispatchIfFenceCurrent(generation: generation) { [weak self] in
                        self?.onCommit?()
                    }
                    return nil
                }
                if typeToFilter && kc == Self.kcDelete {
                    if PickerInputRoutingPolicy.route(
                        nativeEditingAvailable: nativeEditing,
                        pickerAction: nil
                    ) == .searchField {
                        return Unmanaged.passUnretained(event)
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onFilterBackspace?()
                    }
                    return nil
                }
                if let direction = arrowDirection(for: kc) {
                    if PickerInputRoutingPolicy.route(
                        nativeEditingAvailable: nativeEditing,
                        pickerAction: nil
                    ) == .searchField {
                        return Unmanaged.passUnretained(event)
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onNavigate?(direction)
                    }
                    return nil
                }

                let character = PickerKeyInterpreter.logicalCharacter(
                    from: event,
                    translator: KeyboardLayoutTranslator.shared
                )
                if let editingCommand = PickerInputRoutingPolicy.searchEditingCommand(
                    stickySession: sticky,
                    typeToFilter: typeToFilter,
                    commandHeld: cmd,
                    shiftHeld: shift,
                    logicalCharacter: character
                ) {
                    if nativeEditing { return Unmanaged.passUnretained(event) }
                    guard stickyWasReleased else { return nil }
                    DispatchQueue.main.async { [weak self] in
                        self?.onSearchEditingCommand?(editingCommand)
                    }
                    return nil
                }
                let characterAction = PickerKeyInterpreter.action(
                    logicalCharacter: character,
                    keyCode: kc,
                    actionModifierMatches: actionModifierMatches,
                    settingsModifierMatches: cmd || activeBinding?.modifiersHeld(flags) == true,
                    typeToFilter: typeToFilter
                )
                switch PickerInputRoutingPolicy.route(
                    nativeEditingAvailable: nativeEditing,
                    pickerAction: characterAction
                ) {
                case .searchField:
                    return Unmanaged.passUnretained(event)
                case .orderedPicker:
                    beginInputFence()
                    return orderedPickerEvent(
                        event,
                        kind: .pickerCommand,
                        originalKeyCode: kc,
                        originalFlags: flags
                    )
                case .discard:
                    return nil
                case .picker:
                    guard let characterAction else { return nil }
                    let fenced: Bool
                    if case .appendFilter = characterAction { fenced = false }
                    else { fenced = true; beginInputFence() }
                    handleCharacterAction(
                        characterAction,
                        chainSelection: cmd,
                        fenced: fenced
                    )
                    return nil
                }
            }
        }

        if type == .flagsChanged {
            stateLock.lock()
            let shiftRising = shift && !lastShift
            let shiftFalling = !shift && lastShift
            lastShift = shift
            guard armed != nil else {
                stateLock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let armingHeld = armedBinding?.modifiersHeld(flags) ?? false

            // Release-fired so ⇧⌘W closes without stepping first; a pre-arm Shift never sets pending (#143).
            if armingHeld && UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey) {
                if shiftRising {
                    shiftTapPending = true
                } else if shiftFalling && shiftTapPending {
                    shiftTapPending = false
                    stateLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onAdvance?(true)
                    }
                    return nil
                }
            }

            if armedSticky, let armedBinding {
                stickyModifiersReleased = PickerInputRoutingPolicy.updatedStickyModifiersReleased(
                   stickyModifiersReleased,
                   hotkeyMatched: false,
                   required: armedBinding.cgFlags,
                   current: flags
                )
            }

            if !armingHeld {
                if PickerSessionReleasePolicy.action(isSticky: armedSticky) == .commit {
                    beginInputFenceLocked()
                    let generation = dismissalGeneration
                    clearArmedLocked()
                    stateLock.unlock()
                    dispatchIfFenceCurrent(generation: generation) { [weak self] in
                        self?.onCommit?()
                    }
                    return Unmanaged.passUnretained(event)
                }
            }
            stateLock.unlock()
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func orderedPickerEvent(
        _ event: CGEvent,
        kind: PickerInputRoutingPolicy.OrderedEventKind,
        originalKeyCode: CGKeyCode,
        originalFlags: CGEventFlags
    ) -> Unmanaged<CGEvent> {
        let userData = PickerInputRoutingPolicy.orderedEventUserData(
            kind: kind,
            keyCode: originalKeyCode,
            flags: originalFlags
        )
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(
            .keyboardEventKeycode,
            value: Int64(Self.kcOrderedPickerMarker)
        )
        // In particular, never let a tagged Cmd+Q/Cmd+W or Cmd+Tab reach the
        // application/system shortcut machinery with its original meaning.
        event.flags = []
        return Unmanaged.passUnretained(event)
    }

    /// Runs on AppKit's main event path after every earlier field-editor event.
    /// A valid marker is always consumed, even if the picker was dismissed while
    /// it was in flight, so its harmless F20 payload never leaks to a responder.
    func handleOrderedPickerEvent(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent,
              let ordered = PickerInputRoutingPolicy.orderedKeyEvent(
                from: cgEvent.getIntegerValueField(.eventSourceUserData)
              ) else { return false }

        let keyCode = ordered.keyCode
        let flags = ordered.flags
        let shift = flags.contains(.maskShift)
        if ordered.kind == .terminal {
            stateLock.lock()
            let generationBeforeAction = dismissalGeneration
            stateLock.unlock()
            if keyCode == Self.kcEscape { onCancel?() }
            else if keyCode == Self.kcReturn || keyCode == Self.kcKeypadEnter { onCommit?() }
            stateLock.lock()
            let dismissalActuallyStarted = dismissalGeneration != generationBeforeAction
            stateLock.unlock()
            if !dismissalActuallyStarted { finishDismissal() }
            return true
        }
        if ordered.kind == .hotkey {
            stateLock.lock()
            let generationBeforeHotkey = dismissalGeneration
            stateLock.unlock()
            if let stickyBinding = HotkeyConfig.shared[.stickyToggle],
               stickyBinding.matchesTrigger(keyCode: keyCode, flags: flags) {
                onStickyToggle?()
                finishDismissal(ifGenerationUnchangedFrom: generationBeforeHotkey)
                return true
            }
            for (slot, style) in Self.armSlots {
                guard let binding = HotkeyConfig.shared[slot],
                      binding.matchesTrigger(keyCode: keyCode, flags: flags) else { continue }
                armOrAdvance(
                    style,
                    binding: binding,
                    shift: shift,
                    deliverSynchronously: true
                )
                // The physical modifier release can reach the tap before this marker
                // reaches AppKit. Re-read hardware after arming so the new sequence
                // does not remain non-native until the one-second watchdog fires.
                recoverIfReleaseWasMissed()
                finishDismissal(ifGenerationUnchangedFrom: generationBeforeHotkey)
                return true
            }
            finishDismissal(ifGenerationUnchangedFrom: generationBeforeHotkey)
            return true
        }

        stateLock.lock()
        let generationBeforePicker = dismissalGeneration
        let hasArmedPicker = armed != nil
        let sticky = armedSticky
        let activeBinding = armedBinding
        stateLock.unlock()
        defer { finishDismissal(ifGenerationUnchangedFrom: generationBeforePicker) }
        guard hasArmedPicker else { return true }

        let typeToFilter = (UserDefaults.standard.object(
            forKey: SwitchPreferences.typeToFilterKey
        ) as? Bool) ?? true
        let command = flags.contains(.maskCommand)
        let character = KeyboardLayoutTranslator.shared.character(
            for: keyCode,
            shift: shift
        )
        let action = PickerKeyInterpreter.action(
            logicalCharacter: character,
            keyCode: keyCode,
            actionModifierMatches: command && (sticky || !typeToFilter || shift),
            settingsModifierMatches: command || activeBinding?.modifiersHeld(flags) == true,
            typeToFilter: typeToFilter
        )
        switch action {
        case .closeSelected, .closeSelectedApp, .hideSelected, .openSettings, .pickIndex:
            if let action {
                performCharacterAction(action, chainSelection: command)
            }
        case .appendFilter, nil:
            break
        }
        return true
    }

    private func armOrAdvance(
        _ style: ArmStyle,
        binding: HotkeyBinding,
        shift: Bool,
        deliverSynchronously: Bool = false
    ) {
        var effective = style
        effective.sticky = style.sticky || UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
        effective.reverse = shift
        let nextIdentity = PickerArmTransitionPolicy.Identity(
            mode: effective.mode,
            sticky: effective.sticky,
            currentSpaceOnly: effective.currentSpaceOnly
        )
        stateLock.lock()
        let currentIdentity = armed.map {
            PickerArmTransitionPolicy.Identity(
                mode: $0,
                sticky: armedSticky,
                currentSpaceOnly: armedCurrentSpaceOnly
            )
        }
        let transition = PickerArmTransitionPolicy.action(current: currentIdentity, next: nextIdentity)
        if transition == .arm {
            armed = effective.mode
            armedBinding = binding
            armedSticky = effective.sticky
            armedCurrentSpaceOnly = effective.currentSpaceOnly
        } else {
            // Alternate bindings for the same semantic picker still advance,
            // but release detection must follow the binding most recently used.
            armedBinding = binding
        }
        // Repeating the same semantic hotkey is an advance, but it is still a
        // fresh modifier chord. Keep raw events out of the field until this
        // chord has also been fully released.
        stickyModifiersReleased = PickerInputRoutingPolicy.updatedStickyModifiersReleased(
            stickyModifiersReleased,
            hotkeyMatched: true,
            required: binding.cgFlags,
            current: []
        )
        armedSequence &+= 1
        stateLock.unlock()
        let deliver: () -> Void = { [weak self] in
            if transition == .arm { self?.onArm?(effective) }
            else { self?.onAdvance?(shift) }
        }
        if deliverSynchronously { deliver() }
        else { DispatchQueue.main.async(execute: deliver) }
    }

    var isArmed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return armed != nil
    }

    private func clearArmedLocked() {
        armed = nil
        armedBinding = nil
        armedSticky = false
        armedCurrentSpaceOnly = false
        shiftTapPending = false
        searchFieldFocused = false
        stickyModifiersReleased = false
    }

    func clearArmed() {
        stateLock.lock()
        clearArmedLocked()
        stateLock.unlock()
    }

    private func beginInputFenceLocked() {
        if !dismissalPending { bufferedKeyDowns.removeAll(keepingCapacity: true) }
        dismissalPending = true
        dismissalGeneration &+= 1
        replayInFlightGeneration = nil
        let generation = dismissalGeneration
        // A marker cannot acknowledge itself if the event tap is disabled or
        // the panel disappears during routing. Bound that failure so global
        // keyboard input can never remain captured indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.discardBufferedKeyDowns(
                generation: generation,
                reason: "input fence acknowledgement timed out"
            )
        }
    }

    private func beginInputFence() {
        stateLock.lock()
        beginInputFenceLocked()
        stateLock.unlock()
    }

    @discardableResult
    func beginDismissal() -> UInt64 {
        stateLock.lock()
        beginInputFenceLocked()
        let generation = dismissalGeneration
        clearArmedLocked()
        stateLock.unlock()
        return generation
    }

    /// Run a queued tap action only while the fence that authorized it is still
    /// current. A picker command ahead of a modifier-release callback can start
    /// a newer, target-aware dismissal; the stale release must not dismiss the
    /// already torn-down model a second time and bypass that focus barrier.
    private func dispatchIfFenceCurrent(
        generation: UInt64,
        _ action: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrent = self.dismissalPending
                && self.dismissalGeneration == generation
            self.stateLock.unlock()
            guard isCurrent else { return }
            action()
        }
    }

    /// Release buffered keystrokes only after the selected window has actually
    /// received keyboard focus. A PID check is insufficient when two windows of
    /// the same app live on different Spaces.
    func finishDismissal(afterFocusing target: WindowInfo? = nil) {
        stateLock.lock()
        let generation = dismissalGeneration
        stateLock.unlock()
        let deadline = Date().addingTimeInterval(target == nil ? 0 : 2.0)
        DispatchQueue.main.async { [weak self] in
            self?.finishDismissalWhenReady(
                generation: generation,
                target: target,
                deadline: deadline
            )
        }
    }

    private func finishDismissal(ifGenerationUnchangedFrom generation: UInt64) {
        // Keep the generation fixed across the asynchronous handoff. Re-reading
        // it in `finishDismissal()` could accidentally release a newer fence
        // created by a modifier release racing this callback.
        DispatchQueue.main.async { [weak self] in
            self?.finishDismissalWhenReady(
                generation: generation,
                target: nil,
                deadline: Date()
            )
        }
    }

    private func finishDismissalWhenReady(
        generation: UInt64,
        target: WindowInfo?,
        deadline: Date
    ) {
        stateLock.lock()
        let stillPending = dismissalPending && dismissalGeneration == generation
        stateLock.unlock()
        guard stillPending else { return }

        if let target, !WindowFocuser.isFocused(target) {
            guard Date() < deadline else {
                discardBufferedKeyDowns(
                    generation: generation,
                    reason: "target window did not receive focus"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishDismissalWhenReady(
                    generation: generation,
                    target: target,
                    deadline: deadline
                )
            }
            return
        }
        replayBufferedKeyDowns(generation: generation)
    }

    /// A focus timeout must never replay potentially sensitive text into an
    /// arbitrary window. Drop only this fence's buffered events, then allow new
    /// physical input through so the global tap cannot remain wedged forever.
    private func discardBufferedKeyDowns(generation: UInt64, reason: String) {
        stateLock.lock()
        guard dismissalPending, dismissalGeneration == generation else {
            stateLock.unlock()
            return
        }
        let discardedCount = bufferedKeyDowns.count
        bufferedKeyDowns.removeAll(keepingCapacity: true)
        dismissalPending = false
        if replayInFlightGeneration == generation { replayInFlightGeneration = nil }
        stateLock.unlock()
        if discardedCount > 0 {
            NSLog("Switch: \(reason); discarded \(discardedCount) buffered key events")
        }
    }

    private func replayBufferedKeyDowns(generation: UInt64) {
        stateLock.lock()
        guard dismissalPending, dismissalGeneration == generation,
              replayInFlightGeneration != generation else {
            stateLock.unlock()
            return
        }
        replayInFlightGeneration = generation
        let batch = bufferedKeyDowns
        bufferedKeyDowns.removeAll(keepingCapacity: true)
        stateLock.unlock()

        for buffered in batch {
            postReplayedKey(buffered, keyDown: true, generation: generation)
            postReplayedKey(buffered, keyDown: false, generation: generation)
        }
        postReplaySentinel(generation: generation)
    }

    /// The sentinel is observed on the same serial event-tap stream as physical
    /// input and replayed keys. Only that acknowledgement can prove every event
    /// ahead of it has either passed or joined the next buffered batch.
    private func handleReplaySentinel(generation: UInt64) {
        stateLock.lock()
        guard dismissalPending, dismissalGeneration == generation else {
            if replayInFlightGeneration == generation { replayInFlightGeneration = nil }
            stateLock.unlock()
            return
        }
        replayInFlightGeneration = nil
        let needsAnotherBatch = !bufferedKeyDowns.isEmpty
        if !needsAnotherBatch { dismissalPending = false }
        stateLock.unlock()

        if needsAnotherBatch {
            DispatchQueue.main.async { [weak self] in
                self?.replayBufferedKeyDowns(generation: generation)
            }
        }
    }

    private func postReplayedKey(
        _ buffered: BufferedKeyDown,
        keyDown: Bool,
        generation: UInt64
    ) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: buffered.keyCode,
            keyDown: keyDown
        ) else { return }
        event.flags = buffered.flags
        if keyDown && buffered.isRepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        if keyDown {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: PickerInputRoutingPolicy.replayedKeyEventUserData(
                    generation: generation
                )
            )
        }
        event.post(tap: .cghidEventTap)
    }

    private func postReplaySentinel(generation: UInt64) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: Self.kcOrderedPickerMarker,
            keyDown: true
        ) else {
            discardBufferedKeyDowns(
                generation: generation,
                reason: "could not create replay acknowledgement"
            )
            return
        }
        event.flags = []
        event.setIntegerValueField(
            .eventSourceUserData,
            value: PickerInputRoutingPolicy.replaySentinelUserData(
                generation: generation
            )
        )
        event.post(tap: .cghidEventTap)
    }

    func setSuspended(_ value: Bool) {
        stateLock.lock()
        suspended = value
        if value { clearArmedLocked() }
        stateLock.unlock()
    }

    func setSearchFieldFocused(_ value: Bool) {
        stateLock.lock()
        searchFieldFocused = value
        stateLock.unlock()
    }

    func recoverIfReleaseWasMissed() {
        stateLock.lock()
        guard let mode = armed, let binding = armedBinding else {
            stateLock.unlock()
            return
        }
        let sticky = armedSticky
        let sequence = armedSequence
        stateLock.unlock()
        let hardware = CGEventSource.flagsState(.combinedSessionState)
        if sticky {
            guard PickerInputRoutingPolicy.allInvocationModifiersReleased(
                required: binding.cgFlags,
                current: hardware
            ) else { return }
            stateLock.lock()
            guard armed == mode, armedBinding == binding, armedSequence == sequence else {
                stateLock.unlock()
                return
            }
            stickyModifiersReleased = true
            stateLock.unlock()
            return
        }
        guard !binding.modifiersHeld(hardware) else { return }
        stateLock.lock()
        guard armed == mode, armedBinding == binding, armedSequence == sequence else {
            stateLock.unlock()
            return
        }
        clearArmedLocked()
        beginInputFenceLocked()
        let generation = dismissalGeneration
        stateLock.unlock()
        dispatchIfFenceCurrent(generation: generation) { [weak self] in
            self?.onCommit?()
        }
    }

    func reload() {
        reinstall()
    }

    private func reinstall() {
        performOnTapThread { [weak self] in
            self?.uninstallTap()
            self?.installTap()
        }
    }

    private func handleCharacterAction(
        _ action: PickerKeyInterpreter.Action,
        chainSelection: Bool,
        fenced: Bool
    ) {
        stateLock.lock()
        let generationBeforeAction = dismissalGeneration
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.performCharacterAction(action, chainSelection: chainSelection)
            guard fenced else { return }
            self.finishDismissal(ifGenerationUnchangedFrom: generationBeforeAction)
        }
    }

    private func performCharacterAction(
        _ action: PickerKeyInterpreter.Action,
        chainSelection: Bool
    ) {
        switch action {
        case .closeSelected: onCloseSelected?()
        case .closeSelectedApp: onCloseSelectedApp?()
        case .hideSelected: onHideSelected?()
        case .openSettings:
            onCancel?()
            onOpenSettings?()
        case .pickIndex(let index):
            if chainSelection { onPickSelectOnly?(index) }
            else { onPickIndex?(index) }
        case .appendFilter(let character):
            onFilterAppend?(character)
        }
    }

    private func arrowDirection(for kc: CGKeyCode) -> Direction? {
        switch kc {
        case Self.kcLeftArrow:  return .left
        case Self.kcRightArrow: return .right
        case Self.kcDownArrow:  return .down
        case Self.kcUpArrow:    return .up
        default:                return nil
        }
    }

}
