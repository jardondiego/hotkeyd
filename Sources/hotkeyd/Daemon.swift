import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
import HotkeydCore
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

private let hotkeydIOMessageCanSystemSleep: UInt32 = 0xe000_0270
private let hotkeydIOMessageSystemWillSleep: UInt32 = 0xe000_0280
private let hotkeydIOMessageSystemHasPoweredOn: UInt32 = 0xe000_0300

private func hotkeydEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
    return daemon.handle(type: type, event: event)
}

private func hotkeydPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
    switch messageType {
    case hotkeydIOMessageCanSystemSleep, hotkeydIOMessageSystemWillSleep:
        daemon.allowPowerChange(messageArgument)
    case hotkeydIOMessageSystemHasPoweredOn:
        daemon.handleSystemWake()
    default:
        break
    }
}

private func hotkeydKeyboardAttachedCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    var count = 0
    while true {
        let obj = IOIteratorNext(iterator)
        if obj == 0 { break }
        IOObjectRelease(obj)
        count += 1
    }
    guard count > 0, let refcon else { return }
    let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
    daemon.handleKeyboardAttached()
}

private func hotkeydKeyboardRemovedCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    var count = 0
    while true {
        let obj = IOIteratorNext(iterator)
        if obj == 0 { break }
        IOObjectRelease(obj)
        count += 1
    }
    guard count > 0, let refcon else { return }
    let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
    daemon.handleKeyboardRemoved()
}

private final class PendingSelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _target: SelectionReader.TargetApp?

    var target: SelectionReader.TargetApp? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _target
        }
        set {
            lock.lock()
            _target = newValue
            lock.unlock()
        }
    }
}

/// Owns the event tap. Runs under launchd so its Accessibility grant belongs to a stable code
/// identity at a stable path, which is what makes the permission survive rebuilds.
final class Daemon {
    /// Default double-tap window for paired key combos (`tap` + `doubleTap`, e.g. `fn+c` or
    /// `fn+space`) so single-tap actions stay snappy while leaving room for deliberate double-taps.
    static let defaultComboDoubleTapWindow: Double = 0.25

    private let configURL: URL
    private let binaryPath: String
    private let allowAdhoc: Bool
    private let startedAt: String = RuntimeState.timestamp()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var watcher: DispatchSourceFileSystemObject?
    private var debouncedReloadItem: DispatchWorkItem?
    private var debouncedCapsResyncItem: DispatchWorkItem?
    private var signalSource: DispatchSourceSignal?
    private var peekToggleSignalSource: DispatchSourceSignal?
    private var peekSearchSignalSource: DispatchSourceSignal?
    private var terminationSource: DispatchSourceSignal?
    private var capsWatchdog: DispatchSourceTimer?
    private var pauseState: PauseState?
    private var pauseResumeTimer: DispatchSourceTimer?
    private var currentConfigState = Config()
    private var peekHoldWorkItem: DispatchWorkItem?
    private lazy var peekBridge: PeekOverlayBridge = {
        let bridge = PeekOverlayBridge(binaryPath: binaryPath, allowAdhoc: allowAdhoc, queue: controlQueue)
        bridge.onHelperExited = { [weak self] in
            self?.resetPeekModeFromControlQueue()
        }
        return bridge
    }()
    private var cachedSearchUsageFingerprint: StatsAnalyzer.LogFingerprint?
    private var cachedSearchUsageCounts: [String: Int] = [:]
    private var lastPeekSignalUptime: TimeInterval = 0
    private var lastSearchToggleUptime: TimeInterval = 0
    private static let peekSignalMinIntervalSeconds: TimeInterval = 0.15
    private var powerRootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var hidNotifyPort: IONotificationPortRef?
    private var keyboardAttachIterator: io_iterator_t = 0
    private var keyboardRemoveIterator: io_iterator_t = 0
    private var instanceLockFD: Int32 = -1
    private var capsRemapped = false
    private var capsNeeded = false
    private var lastCapsRecovery = Date.distantPast

    private var tapActiveState = false
    private var tapNoteState = "starting"
    private var configValidState = true
    private var configErrorState: String?
    private var activeBindingsState = 0
    private var waitingForAccessibility = false

    private let lock = NSLock()
    private var index = BindingIndex()
    private var held = HeldModifiers()
    private var wasInSecureInput = false
    private var isPausedLocked = false
    private var pauseResumeDateLocked: Date?
    private var pauseExpiryDispatchedLocked = false
    private enum ActivePeekMode: Equatable {
        case idle
        case hold(Modifier)
        case pinned
    }
    private var peekConfigLocked: PeekConfig = .default
    private var peekModeLocked: ActivePeekMode = .idle
    private var peekArmingTriggerLocked: Modifier?
    private var peekPinnedWaitForClearLocked = false
    private var peekGenerationLocked: UInt64 = 0
    /// Keys whose keyDown we swallowed, so the matching keyUp can be swallowed too instead of
    /// leaking a stray release into the focused app.
    private var swallowedKeys: Set<UInt16> = []
    private var detector = DoubleTapDetector()
    private var sequenceDetector = SequenceDetector()
    /// The last press of a key that also has a double-tap binding, for hold-fn-tap-esc-twice.
    private var lastKeyTap: (combo: KeyCombo, at: Double)?
    /// A single-press action waiting out the double-tap window. Kept under `lock`.
    private var pendingKeyTap: (
        combo: KeyCombo,
        shortcut: Shortcut,
        generation: UInt64,
        selectionBox: PendingSelectionBox?
    )?
    private var keyTapGeneration: UInt64 = 0
    private var keyTapCooldownUntil: [KeyCombo: Double] = [:]
    private let keyTapQueue = DispatchQueue(label: "io.github.jardondiego.hotkeyd.key-tap")
    private let controlQueue = DispatchQueue(label: "io.github.jardondiego.hotkeyd.control", qos: .utility)

    init(configURL: URL = Paths.config, binaryPath: String, allowAdhoc: Bool = false) {
        self.configURL = configURL
        self.binaryPath = binaryPath
        self.allowAdhoc = allowAdhoc
    }

    func start() {
        Log.daemon("hotkeyd daemon starting pid=\(getpid()) binary=\(binaryPath)")
        do {
            try StrictModes.verifySecurePath(binaryPath, expectRegularFile: true)
            _ = try CodeTrust.verify(binaryPath: binaryPath, allowAdhoc: allowAdhoc)
            _ = try CodeTrust.verifyCurrentProcess(expectedBinaryPath: binaryPath, allowAdhoc: allowAdhoc)
        } catch {
            Log.daemon("code trust check failed: \(error.localizedDescription)")
            Log.flush()
            exit(5)
        }
        let defaultConfigPath = Paths.config.standardizedFileURL.path
        let activeConfigPath = configURL.standardizedFileURL.path
        if allowAdhoc || activeConfigPath != defaultConfigPath {
            ShellRunner.disallowAccessibilityDelegation = true
            Log.daemon("accessibility delegation disabled for child shells (adhoc=\(allowAdhoc), customConfig=\(activeConfigPath != defaultConfigPath))")
        }
        do {
            try Paths.ensureDirectories()
            Log.rotateDaemonLogIfNeeded()
            try acquireSingleInstanceLock()
        } catch {
            Log.daemon("daemon startup aborted: \(error.localizedDescription)")
            Log.flush()
            exit(6)
        }
        // Ignore managed signals BEFORE writing runtime-state.json / starting reload so early
        // reload, peek, or termination signals during startup never hit default POSIX termination.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        controlQueue.sync {
            persistRuntimeStateLocked()
            reload()
            watchConfigDirectory()
            registerPowerAndKeyboardObservers()
        }
        watchForReloadSignal()
        watchForPeekToggleSignal()
        watchForPeekSearchSignal()
        watchForTermination()
        startCapsWatchdog()
        waitForAccessibility()
    }

    private func acquireSingleInstanceLock() throws {
        try StrictModes.verifySecurePath(Paths.root.path, expectRegularFile: false)
        let dirFD = try StrictModes.openVerifiedDirectory(Paths.root.path)
        defer { close(dirFD) }

        let fd = openat(
            dirFD,
            "daemon.lock",
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            0o600
        )
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "could not open daemon.lock: \(String(cString: strerror(errno)))"]
            )
        }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              fchmod(fd, 0o600) == 0 else {
            let err = errno
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "daemon.lock failed ownership/type check"]
            )
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "another hotkeyd daemon instance is already running"]
            )
        }
        instanceLockFD = fd
    }

    // MARK: - Runtime State Snapshot

    private func updateRuntimeState(
        tapActive: Bool? = nil,
        tapNote: String? = nil,
        configValid: Bool? = nil,
        configError: String?? = nil,
        activeBindings: Int? = nil
    ) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            if let tapActive { self.tapActiveState = tapActive }
            if let tapNote { self.tapNoteState = tapNote }
            if let configValid { self.configValidState = configValid }
            if let configError { self.configErrorState = configError }
            if let activeBindings { self.activeBindingsState = activeBindings }
            self.persistRuntimeStateLocked()
        }
    }

    /// Must only be called on `controlQueue`.
    private func persistRuntimeStateLocked() {
        lock.lock()
        let secureInput = wasInSecureInput
        let remapped = capsRemapped
        lock.unlock()

        let snapshot = RuntimeState(
            pid: getpid(),
            startedAt: startedAt,
            updatedAt: RuntimeState.timestamp(),
            binaryPath: binaryPath,
            configPath: configURL.path,
            tapActive: tapActiveState,
            tapNote: tapNoteState,
            secureInputActive: secureInput,
            paused: pauseState != nil,
            pausedUntil: pauseState?.resumeAt,
            pauseReason: pauseState?.reason,
            capsRemapped: remapped,
            peekEnabled: currentConfigState.peek.enabled,
            activeBindings: activeBindingsState,
            configValid: configValidState,
            configError: configErrorState
        )
        try? snapshot.save(to: Paths.runtimeState)
    }

    // MARK: - Power (Sleep/Wake) & Keyboard Hotplug Observers

    /// Must be called on `controlQueue`.
    private func registerPowerAndKeyboardObservers() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var pPort: IONotificationPortRef?
        let rootPort = IORegisterForSystemPower(
            refcon,
            &pPort,
            hotkeydPowerCallback,
            &powerNotifier
        )
        if rootPort != 0, let pPort {
            powerRootPort = rootPort
            powerNotifyPort = pPort
            IONotificationPortSetDispatchQueue(pPort, controlQueue)
        }

        if let hPort = IONotificationPortCreate(kIOMainPortDefault) {
            hidNotifyPort = hPort
            IONotificationPortSetDispatchQueue(hPort, controlQueue)

            if let attachMatch = Self.keyboardMatchingDictionary() {
                var attachIter: io_iterator_t = 0
                let rc = IOServiceAddMatchingNotification(
                    hPort,
                    kIOFirstMatchNotification,
                    attachMatch,
                    hotkeydKeyboardAttachedCallback,
                    refcon,
                    &attachIter
                )
                if rc == KERN_SUCCESS {
                    keyboardAttachIterator = attachIter
                    while case let obj = IOIteratorNext(attachIter), obj != 0 {
                        IOObjectRelease(obj)
                    }
                }
            }

            if let removeMatch = Self.keyboardMatchingDictionary() {
                var removeIter: io_iterator_t = 0
                let rc = IOServiceAddMatchingNotification(
                    hPort,
                    kIOTerminatedNotification,
                    removeMatch,
                    hotkeydKeyboardRemovedCallback,
                    refcon,
                    &removeIter
                )
                if rc == KERN_SUCCESS {
                    keyboardRemoveIterator = removeIter
                    while case let obj = IOIteratorNext(removeIter), obj != 0 {
                        IOObjectRelease(obj)
                    }
                }
            }
        }
    }

    private static func keyboardMatchingDictionary() -> CFMutableDictionary? {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else {
            return nil
        }
        matching[kIOHIDPrimaryUsagePageKey] = Int(kHIDPage_GenericDesktop)
        matching[kIOHIDPrimaryUsageKey] = Int(kHIDUsage_GD_Keyboard)
        return matching
    }

    func allowPowerChange(_ messageArgument: UnsafeMutableRawPointer?) {
        guard powerRootPort != 0 else { return }
        _ = IOAllowPowerChange(powerRootPort, Int(bitPattern: messageArgument))
    }

    func handleSystemWake() {
        Log.daemon("system wake detected; resetting modifier state and re-syncing caps lock")
        lock.lock()
        held.reset()
        detector = DoubleTapDetector(windowOverrides: detector.windowOverrides)
        sequenceDetector.reset()
        swallowedKeys.removeAll()
        cancelPendingKeyTapLocked()
        lastKeyTap = nil
        resetPeekStateLocked()
        lock.unlock()
        applyPeekEffect(.hide)
        syncPauseState(notifyOnExpiry: true)
        scheduleCapsResync(delaySeconds: 0.4, reason: "wake")
    }

    func handleKeyboardAttached() {
        scheduleCapsResync(delaySeconds: 0.35, reason: "keyboard attach")
    }

    func handleKeyboardRemoved() {
        lock.lock()
        held.setCapsLock(false)
        lock.unlock()
    }

    private func scheduleCapsResync(delaySeconds: Double, reason: String) {
        controlQueue.async { [weak self] in
            guard let self, self.capsNeeded, self.pauseState == nil, self.currentTap != nil else { return }
            self.debouncedCapsResyncItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.capsNeeded, self.pauseState == nil, self.currentTap != nil else { return }
                Log.daemon("re-applying caps lock remap after \(reason)")
                self.syncCapsLock(forceReapply: true)
            }
            self.debouncedCapsResyncItem = item
            self.controlQueue.asyncAfter(deadline: .now() + delaySeconds, execute: item)
        }
    }

    // MARK: - Event tap

    private func waitForAccessibility() {
        lock.lock()
        if waitingForAccessibility {
            lock.unlock()
            return
        }
        waitingForAccessibility = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var prompted = false
            let waitStarted = Date()
            var lastReminder = Date.distantPast
            while let self {
                if AXIsProcessTrusted() {
                    self.lock.lock()
                    self.waitingForAccessibility = false
                    self.lock.unlock()
                    Log.daemon("accessibility granted")
                    self.installTap()
                    return
                }
                if !prompted {
                    prompted = true
                    if case .enabled = CapsLock.state() {
                        try? CapsLock.disable()
                        Log.daemon("cleared stranded caps lock remap while waiting for accessibility")
                    }
                    self.updateRuntimeState(
                        tapActive: false,
                        tapNote: "Accessibility permission not granted"
                    )
                    let suppressModal = RuntimeState.consumeSuppressAXPromptSentinel(
                        at: Paths.suppressAXPromptSentinel
                    )
                    if !suppressModal {
                        let options = [
                            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                        ] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                    Log.daemon("accessibility not granted yet; tap inactive" + (suppressModal ? " (modal prompt suppressed)" : ""))
                    Log.daemon("enable \"hotkeyd\" in System Settings > Privacy & Security > Accessibility")
                    Log.daemon("binary: \(self.binaryPath)")
                    lastReminder = Date()
                } else if Date().timeIntervalSince(lastReminder) > 30 {
                    lastReminder = Date()
                    Log.daemon("still waiting for accessibility; tap inactive")
                }
                let pollInterval: TimeInterval = Date().timeIntervalSince(waitStarted) < 60 ? 1 : 2
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
    }

    private var currentTap: CFMachPort? {
        lock.lock()
        defer { lock.unlock() }
        return tap
    }

    private func teardownTap() {
        lock.lock()
        let oldTap = tap
        let oldSource = runLoopSource
        let oldRL = tapRunLoop
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        held.reset()
        swallowedKeys.removeAll()
        cancelPendingKeyTapLocked()
        lastKeyTap = nil
        resetPeekStateLocked()
        lock.unlock()
        controlQueue.async { [weak self] in
            self?.applyPeekEffect(.hide)
        }

        if let oldTap {
            CGEvent.tapEnable(tap: oldTap, enable: false)
            CFMachPortInvalidate(oldTap)
        }
        if let oldRL, let oldSource {
            CFRunLoopRemoveSource(oldRL, oldSource, .commonModes)
            CFRunLoopStop(oldRL)
        }
    }

    private func installTap() {
        guard currentTap == nil else { return }

        let interesting: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        let mask = interesting.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeydEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            updateRuntimeState(tapActive: false, tapNote: "event tap creation failed; retrying")
            Log.daemon("event tap could not be created; retrying in 2s")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.installTap()
            }
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            Log.daemon("could not create run loop source for the tap")
            CFMachPortInvalidate(createdTap)
            return
        }

        lock.lock()
        tap = createdTap
        runLoopSource = source
        lock.unlock()

        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()
            self.lock.lock()
            self.tapRunLoop = rl
            self.lock.unlock()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)
            Log.daemon("event tap installed; listening for shortcuts")
            self.updateRuntimeState(tapActive: true, tapNote: "listening for shortcuts")
            self.controlQueue.async { [weak self] in
                self?.syncCapsLock(forceReapply: false)
            }
            CFRunLoopRun()
        }
        thread.name = "io.github.jardondiego.hotkeyd.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let activeTap = currentTap {
                CGEvent.tapEnable(tap: activeTap, enable: true)
            }
            // A modifier or key may have been released while the tap was off; do not leave it stuck.
            lock.lock()
            held.reset()
            detector = DoubleTapDetector(windowOverrides: detector.windowOverrides)
            sequenceDetector.reset()
            swallowedKeys.removeAll()
            cancelPendingKeyTapLocked()
            lastKeyTap = nil
            let tapDisablePeek = cancelOrHidePeekLocked()
            lock.unlock()
            // Always hide even when `tapDisablePeek == .none`, since Search HUD runs with
            // `peekModeLocked == .idle` and must also dismiss when the tap is disabled.
            controlQueue.async { [weak self] in
                guard let self else { return }
                if tapDisablePeek != .none {
                    self.applyPeekEffect(tapDisablePeek)
                } else {
                    self.peekBridge.hide()
                }
            }
            Log.daemon("tap disabled by the system (\(type == .tapDisabledByUserInput ? "user input" : "timeout")); re-enabled")
            return Unmanaged.passUnretained(event)
        }

        // Pause all modifier gestures, sequences, and chords during macOS Secure Event Input so
        // typing shifted characters in a password prompt can never steal focus mid-entry. Still
        // swallow remapped Caps Lock (F18) so tapping Caps Lock never injects raw F18 text.
        if IsSecureEventInputEnabled() {
            var enteredSecureInput = false
            var swallowF18 = false
            let keyCode = (type == .keyDown || type == .keyUp)
                ? UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                : UInt16.max

            lock.lock()
            if !wasInSecureInput {
                wasInSecureInput = true
                enteredSecureInput = true
                held.reset()
                detector = DoubleTapDetector(windowOverrides: detector.windowOverrides)
                sequenceDetector.reset()
                swallowedKeys.removeAll()
                cancelPendingKeyTapLocked()
                lastKeyTap = nil
            }
            let securePeek = cancelOrHidePeekLocked()
            if capsRemapped && keyCode == CapsLock.targetKeyCode {
                swallowF18 = true
            }
            lock.unlock()

            // Dismiss Search HUD too when Secure Event Input turns on (even when peekModeLocked == .idle).
            if securePeek != .none || enteredSecureInput {
                controlQueue.async { [weak self] in
                    guard let self else { return }
                    if securePeek != .none {
                        self.applyPeekEffect(securePeek)
                    } else {
                        self.peekBridge.hide()
                    }
                }
            }
            if enteredSecureInput {
                Log.daemon("secure event input enabled; pausing shortcuts")
                updateRuntimeState()
            }
            return swallowF18 ? nil : Unmanaged.passUnretained(event)
        }

        // Transparent pass-through while temporarily paused via `hotkeyd pause`. Still clear any
        // prior `wasInSecureInput` latch first, swallow F18 if Caps Lock disable hasn't finished,
        // and gate expiry resync with a one-shot latch so high-rate events cannot flood controlQueue.
        var exitedSecureInputWhilePaused = false
        var shouldSyncExpiredPause = false
        var swallowF18WhilePaused = false
        lock.lock()
        let pausedNow = isPausedLocked
        if pausedNow {
            if wasInSecureInput {
                wasInSecureInput = false
                exitedSecureInputWhilePaused = true
            }
            if capsRemapped && (type == .keyDown || type == .keyUp) {
                let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                if keyCode == CapsLock.targetKeyCode {
                    swallowF18WhilePaused = true
                }
            }
            if let pausedExpiry = pauseResumeDateLocked,
               Date() >= pausedExpiry,
               !pauseExpiryDispatchedLocked {
                pauseExpiryDispatchedLocked = true
                shouldSyncExpiredPause = true
            }
        }
        lock.unlock()
        if exitedSecureInputWhilePaused {
            Log.daemon("secure event input ended")
            updateRuntimeState()
        }
        if pausedNow {
            if shouldSyncExpiredPause {
                controlQueue.async { [weak self] in
                    self?.syncPauseState(notifyOnExpiry: true)
                }
            }
            return swallowF18WhilePaused ? nil : Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let physicalFnDown = CGEventSource.keyState(.hidSystemState, key: 63)
        var exitedSecureInput = false
        var fired: [(shortcut: Shortcut, selectionTarget: SelectionReader.TargetApp?)] = []
        var swallow = false
        var peekEffect: PeekEffect = .none

        lock.lock()
        if wasInSecureInput {
            wasInSecureInput = false
            exitedSecureInput = true
        }

        switch type {
        case .flagsChanged:
            let modifierCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            held.update(
                keyCode: modifierCode,
                flags: event.flags,
                physicalFnDown: modifierCode == 63 ? nil : physicalFnDown
            )
            // Releasing fn ends the "hold fn, tap esc twice" gesture; fire the single action now
            // instead of making the user wait out the rest of the window.
            if let pending = takePendingKeyTapLocked() {
                fired.append((pending.shortcut, pending.selectionBox?.target))
            }
            lastKeyTap = nil
            var doubleTapFired = false
            var toggledPeekByModifier = false
            if let modifier = detector.handle(.modifiers(held.keys, at: now)) {
                if peekConfigLocked.enabled,
                   case .modifier(let toggleMod) = peekConfigLocked.toggle,
                   PeekModel.modifier(modifier, satisfies: toggleMod) {
                    peekEffect = togglePinnedPeekLocked()
                    toggledPeekByModifier = true
                    doubleTapFired = true
                } else if peekConfigLocked.enabled,
                          case .modifier(let searchMod) = peekConfigLocked.searchToggle,
                          PeekModel.modifier(modifier, satisfies: searchMod) {
                    resetPeekStateLocked()
                    peekEffect = .toggleSearch
                    toggledPeekByModifier = true
                    doubleTapFired = true
                } else if let shortcut = index.shortcut(forGesture: modifier) {
                    fired.append((shortcut, nil))
                    doubleTapFired = true
                }
            }
            sequenceDetector.onModifiers(held.keys, at: now, doubleTapFired: doubleTapFired)
            if !toggledPeekByModifier {
                if doubleTapFired || !fired.isEmpty {
                    peekEffect = cancelOrHidePeekLocked()
                } else {
                    peekEffect = updatePeekForModifiersLocked(heldKeys: held.keys)
                }
            }

        case .keyDown:
            held.reconcile(with: event.flags, physicalFnDown: physicalFnDown)
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let combo = KeyCombo(keyCode: keyCode, modifiers: held.keys)

            // Any other key resolves a pending single press immediately; only the same combo
            // gets to wait for a second tap.
            if !isRepeat, pendingKeyTap != nil, pendingKeyTap?.combo != combo,
               let pending = takePendingKeyTapLocked() {
                fired.append((pending.shortcut, pending.selectionBox?.target))
            }
            if !isRepeat, lastKeyTap?.combo != combo {
                lastKeyTap = nil
            }

            if capsRemapped && keyCode == CapsLock.targetKeyCode {
                swallow = true
                guard !isRepeat else { break }
                if let pending = takePendingKeyTapLocked() {
                    fired.append((pending.shortcut, pending.selectionBox?.target))
                }
                lastKeyTap = nil
                held.setCapsLock(true)
                // Only a real chord should block the gesture. `fn` shows up spuriously on
                // synthetic F18 events and is not something a user holds while tapping Caps.
                let gestureHeld = held.keys.subtracting([.fn])
                var doubleTapFired = false
                var toggledPeekByModifier = false
                if let modifier = detector.handle(.modifiers(gestureHeld, at: now)) {
                    if peekConfigLocked.enabled,
                       case .modifier(let toggleMod) = peekConfigLocked.toggle,
                       PeekModel.modifier(modifier, satisfies: toggleMod) {
                        peekEffect = togglePinnedPeekLocked()
                        toggledPeekByModifier = true
                        doubleTapFired = true
                    } else if peekConfigLocked.enabled,
                              case .modifier(let searchMod) = peekConfigLocked.searchToggle,
                              PeekModel.modifier(modifier, satisfies: searchMod) {
                        resetPeekStateLocked()
                        peekEffect = .toggleSearch
                        toggledPeekByModifier = true
                        doubleTapFired = true
                    } else if let shortcut = index.shortcut(forGesture: modifier) {
                        fired.append((shortcut, nil))
                        doubleTapFired = true
                    }
                }
                sequenceDetector.onModifiers(gestureHeld, at: now, doubleTapFired: doubleTapFired)
                if !toggledPeekByModifier {
                    if doubleTapFired || !fired.isEmpty {
                        peekEffect = cancelOrHidePeekLocked()
                    } else {
                        peekEffect = updatePeekForModifiersLocked(heldKeys: gestureHeld)
                    }
                }
                break
            }

            if isRepeat && swallowedKeys.contains(keyCode) {
                swallow = true
                if !DoubleTapDetector.isModifierArtifact(keyCode) {
                    sequenceDetector.cancel()
                }
                break
            }

            // Pinned peek overlay: Esc (with no modifiers) dismisses cleanly and is swallowed.
            if peekConfigLocked.enabled && peekModeLocked == .pinned && keyCode == 53 && held.isEmpty {
                swallow = true
                swallowedKeys.insert(keyCode)
                if !isRepeat {
                    peekEffect = cancelOrHidePeekLocked()
                }
                break
            }

            // Optional configured hands-free peek toggle key combo (e.g. fn+h).
            if peekConfigLocked.enabled,
               case .combo(let toggleCombo) = peekConfigLocked.toggle,
               toggleCombo.matches(keyCode: keyCode, held: held) {
                swallow = true
                swallowedKeys.insert(keyCode)
                if !isRepeat {
                    _ = detector.handle(.key(code: keyCode, at: now))
                    sequenceDetector.cancel()
                    lastKeyTap = nil
                    peekEffect = togglePinnedPeekLocked(waitForModifierClear: !held.keys.isEmpty)
                }
                break
            }

            // Optional configured Spotlight search toggle key combo (e.g. fn+k).
            if peekConfigLocked.enabled,
               case .combo(let searchCombo) = peekConfigLocked.searchToggle,
               searchCombo.matches(keyCode: keyCode, held: held) {
                swallow = true
                swallowedKeys.insert(keyCode)
                if !isRepeat {
                    _ = detector.handle(.key(code: keyCode, at: now))
                    sequenceDetector.cancel()
                    lastKeyTap = nil
                    resetPeekStateLocked()
                    peekEffect = .toggleSearch
                }
                break
            }

            // Hold-peek "pin in place": tapping Tab while hold-peek is visible switches to
            // pinned mode without flashing modifier spotlight while the user releases fn.
            if case .hold = peekModeLocked,
               keyCode == 48,
               index.shortcut(keyCode: keyCode, held: held) == nil,
               index.doubleTapShortcut(keyCode: keyCode, held: held) == nil {
                swallow = true
                swallowedKeys.insert(keyCode)
                if !isRepeat {
                    _ = detector.handle(.key(code: keyCode, at: now))
                    sequenceDetector.cancel()
                    lastKeyTap = nil
                    peekArmingTriggerLocked = nil
                    peekPinnedWaitForClearLocked = !held.keys.isEmpty
                    peekGenerationLocked &+= 1
                    peekModeLocked = .pinned
                    peekEffect = .showPinned
                }
                break
            }

            // Pressing any real non-modifier key dismisses hold-peek or cancels arming so a
            // spotted binding (e.g. holding fn then pressing c) fires seamlessly in one motion.
            if !DoubleTapDetector.isModifierArtifact(keyCode), peekModeLocked != .pinned {
                peekEffect = cancelOrHidePeekLocked()
            }

            _ = detector.handle(.key(code: keyCode, at: now))

            if let candidate = sequenceDetector.consumeKeyDown(keyCode: keyCode, held: held, isRepeat: isRepeat, at: now) {
                if peekConfigLocked.enabled,
                   case .sequence(let toggleSeq) = peekConfigLocked.toggle,
                   toggleSeq.keyCode == keyCode,
                   PeekModel.modifier(candidate.leader, satisfies: toggleSeq.leader),
                   candidate.elapsed <= sequenceDetector.defaultMaxDelay {
                    swallow = true
                    swallowedKeys.insert(keyCode)
                    lastKeyTap = nil
                    peekEffect = togglePinnedPeekLocked()
                    break
                }
                if peekConfigLocked.enabled,
                   case .sequence(let searchSeq) = peekConfigLocked.searchToggle,
                   searchSeq.keyCode == keyCode,
                   PeekModel.modifier(candidate.leader, satisfies: searchSeq.leader),
                   candidate.elapsed <= sequenceDetector.defaultMaxDelay {
                    swallow = true
                    swallowedKeys.insert(keyCode)
                    lastKeyTap = nil
                    resetPeekStateLocked()
                    peekEffect = .toggleSearch
                    break
                }
                if let seqShortcut = index.sequenceShortcut(leader: candidate.leader, keyCode: keyCode) {
                    let maxDelay = seqShortcut.maxSequenceDelaySeconds ?? sequenceDetector.defaultMaxDelay
                    if candidate.elapsed <= maxDelay {
                        if !seqShortcut.passThrough {
                            swallow = true
                            swallowedKeys.insert(keyCode)
                        }
                        fired.append((seqShortcut, nil))
                        lastKeyTap = nil
                        if peekModeLocked == .pinned {
                            peekEffect = cancelOrHidePeekLocked()
                        }
                        break
                    }
                }
            }

            // Bare `/` while pinned transitions smoothly from pinned bento peek into Search HUD
            // (checked after sequences so `fn > /` toggles/sequences always take precedence).
            if peekConfigLocked.enabled && peekModeLocked == .pinned && keyCode == 44 && held.isEmpty {
                swallow = true
                swallowedKeys.insert(keyCode)
                if !isRepeat {
                    lastKeyTap = nil
                    resetPeekStateLocked()
                    peekEffect = .toggleSearch
                }
                break
            }

            if let doubleShortcut = index.doubleTapShortcut(keyCode: keyCode, held: held) {
                let window = doubleShortcut.maxDoubleTapDelaySeconds ?? Self.defaultComboDoubleTapWindow
                if now < (keyTapCooldownUntil[combo] ?? 0) {
                    // A third tap must not turn the double-tap action back into a single-tap action.
                    if !doubleShortcut.passThrough {
                        swallow = true
                        swallowedKeys.insert(keyCode)
                    }
                    lastKeyTap = nil
                    break
                }

                if !isRepeat, let last = lastKeyTap, last.combo == combo,
                   now - last.at <= window {
                    // Second tap: cancel the waiting single action, run only the double one.
                    cancelPendingKeyTapLocked()
                    lastKeyTap = nil
                    keyTapCooldownUntil[combo] = now + max(0.25, window)
                    fired.append((doubleShortcut, nil))
                    if !doubleShortcut.passThrough {
                        swallow = true
                        swallowedKeys.insert(keyCode)
                    }
                } else if !isRepeat {
                    // First tap: hold the single action until the window closes. Releasing the
                    // modifier or pressing another key flushes it early.
                    if let pending = takePendingKeyTapLocked() {
                        fired.append((pending.shortcut, pending.selectionBox?.target))
                    }
                    lastKeyTap = (combo, now)
                    if let singleShortcut = index.shortcut(keyCode: keyCode, held: held) {
                        let selectionBox = singleShortcut.usesSelectedText
                            ? captureSelectionTargetAsync()
                            : nil
                        scheduleKeyTapLocked(
                            shortcut: singleShortcut,
                            combo: combo,
                            delay: window,
                            selectionBox: selectionBox
                        )
                        if !singleShortcut.passThrough {
                            swallow = true
                            swallowedKeys.insert(keyCode)
                        }
                    } else if !doubleShortcut.passThrough {
                        // Double-tap-only combo (e.g. fn+e): swallow tap #1 so macOS does not
                        // treat it as a regular shortcut (like Globe+E Emoji Picker) before tap #2.
                        swallow = true
                        swallowedKeys.insert(keyCode)
                    }
                } else if swallowedKeys.contains(keyCode) {
                    // Auto-repeat: only swallow when the initial keyDown was swallowed so we never
                    // orphan a passed-through keyDown without its matching keyUp.
                    swallow = true
                }
            } else if let shortcut = index.shortcut(keyCode: keyCode, held: held) {
                if !shortcut.passThrough {
                    swallow = true
                    swallowedKeys.insert(keyCode)
                }
                // Auto-repeat must stay swallowed, but must not fire the action again.
                if !isRepeat {
                    fired.append((shortcut, nil))
                    lastKeyTap = nil
                }
            } else {
                lastKeyTap = nil
            }
            if !swallow {
                swallowedKeys.remove(keyCode)
            }
            if peekModeLocked == .pinned && (!fired.isEmpty || pendingKeyTap != nil) {
                peekEffect = cancelOrHidePeekLocked()
            }

        case .keyUp:
            held.reconcile(with: event.flags, physicalFnDown: physicalFnDown)
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if capsRemapped && keyCode == CapsLock.targetKeyCode {
                swallow = true
                if let pending = takePendingKeyTapLocked() {
                    fired.append((pending.shortcut, pending.selectionBox?.target))
                }
                lastKeyTap = nil
                held.setCapsLock(false)
                let gestureHeld = held.keys.subtracting([.fn])
                var doubleTapFired = false
                var toggledPeekByModifier = false
                if let modifier = detector.handle(.modifiers(gestureHeld, at: now)) {
                    if peekConfigLocked.enabled,
                       case .modifier(let toggleMod) = peekConfigLocked.toggle,
                       PeekModel.modifier(modifier, satisfies: toggleMod) {
                        peekEffect = togglePinnedPeekLocked()
                        toggledPeekByModifier = true
                        doubleTapFired = true
                    } else if peekConfigLocked.enabled,
                              case .modifier(let searchMod) = peekConfigLocked.searchToggle,
                              PeekModel.modifier(modifier, satisfies: searchMod) {
                        resetPeekStateLocked()
                        peekEffect = .toggleSearch
                        toggledPeekByModifier = true
                        doubleTapFired = true
                    } else if let shortcut = index.shortcut(forGesture: modifier) {
                        fired.append((shortcut, nil))
                        doubleTapFired = true
                    }
                }
                sequenceDetector.onModifiers(gestureHeld, at: now, doubleTapFired: doubleTapFired)
                if !toggledPeekByModifier {
                    if doubleTapFired || !fired.isEmpty {
                        peekEffect = cancelOrHidePeekLocked()
                    } else {
                        peekEffect = updatePeekForModifiersLocked(heldKeys: gestureHeld)
                    }
                }
                break
            }
            if swallowedKeys.remove(keyCode) != nil {
                swallow = true
            }
            // Note: do NOT feed .keyUp to DoubleTapDetector; releasing the last typed letter while
            // beginning a modifier double-tap (fast typing rollover) must not cancel tap #1.

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let pending = takePendingKeyTapLocked() {
                fired.append((pending.shortcut, pending.selectionBox?.target))
            }
            lastKeyTap = nil
            _ = detector.handle(.mouse(at: now))
            sequenceDetector.onMouse()
            peekEffect = cancelOrHidePeekLocked()

        case .scrollWheel:
            if let pending = takePendingKeyTapLocked() {
                fired.append((pending.shortcut, pending.selectionBox?.target))
            }
            lastKeyTap = nil
            _ = detector.handle(.mouse(at: now))
            sequenceDetector.onMouse()
            if peekModeLocked != .pinned {
                peekEffect = cancelOrHidePeekLocked()
            }

        default:
            break
        }
        lock.unlock()

        if peekEffect != .none {
            controlQueue.async { [weak self] in
                self?.applyPeekEffect(peekEffect)
            }
        } else if !fired.isEmpty {
            // Auto-hide any visible Search HUD when the user invokes a global shortcut directly
            // (e.g. searching "ocr" and pressing ⇪ › O). No-op when helper is not running.
            controlQueue.async { [weak self] in
                self?.peekBridge.hide()
            }
        }

        if exitedSecureInput {
            Log.daemon("secure event input ended; resuming shortcuts")
            updateRuntimeState()
        }

        for item in fired {
            Log.daemon("fire \(item.shortcut.trigger.display) -> \(item.shortcut.displayName)")
            ShellRunner.spawn(shortcut: item.shortcut, selectionTarget: item.selectionTarget)
        }

        // Modifier events always pass through: a gesture consumes nothing, so it can never drop a
        // modifier or leave a key stuck. Only an explicitly bound key combo is swallowed.
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Key double-tap helpers (call with `lock` held)

    private func captureSelectionTargetAsync() -> PendingSelectionBox {
        let box = PendingSelectionBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.target = SelectionReader.resolveFrontmostTarget()
        }
        return box
    }

    /// Cancel a waiting single action and return it, so it can fire immediately.
    private func takePendingKeyTapLocked() -> (shortcut: Shortcut, selectionBox: PendingSelectionBox?)? {
        keyTapGeneration &+= 1
        guard let pending = pendingKeyTap else { return nil }
        pendingKeyTap = nil
        return (pending.shortcut, pending.selectionBox)
    }

    /// Drop a waiting single action without firing it.
    private func cancelPendingKeyTapLocked() {
        keyTapGeneration &+= 1
        pendingKeyTap = nil
    }

    private func scheduleKeyTapLocked(
        shortcut: Shortcut,
        combo: KeyCombo,
        delay: Double,
        selectionBox: PendingSelectionBox?
    ) {
        cancelPendingKeyTapLocked()
        let generation = keyTapGeneration
        pendingKeyTap = (combo, shortcut, generation, selectionBox)
        keyTapQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let pending = self.pendingKeyTap, pending.generation == generation else {
                self.lock.unlock()
                return
            }
            self.pendingKeyTap = nil
            if self.lastKeyTap?.combo == pending.combo {
                self.lastKeyTap = nil
            }
            self.lock.unlock()
            Log.daemon("fire \(pending.shortcut.trigger.display) -> \(pending.shortcut.displayName)")
            ShellRunner.spawn(
                shortcut: pending.shortcut,
                selectionTarget: pending.selectionBox?.target
            )
        }
    }

    // MARK: - Configuration

    /// Must be called on `controlQueue`.
    private func reload() {
        syncPauseState(notifyOnExpiry: false)
        do {
            let config = try Config.load(from: configURL)
            try config.validate()

            var overrides: [Modifier: Double] = [:]
            for shortcut in config.shortcuts where shortcut.enabled {
                if let modifier = shortcut.keys.modifier,
                   let delay = shortcut.maxDoubleTapDelaySeconds {
                    overrides[modifier] = delay
                }
            }
            let newIndex = BindingIndex(shortcuts: config.shortcuts)
            currentConfigState = config

            lock.lock()
            index = newIndex
            peekConfigLocked = config.peek
            resetPeekStateLocked()
            detector.windowOverrides = overrides
            sequenceDetector.reset()
            cancelPendingKeyTapLocked()
            lastKeyTap = nil
            keyTapCooldownUntil.removeAll()
            lock.unlock()
            applyPeekEffect(.hide)

            capsNeeded = config.requiresCapsLockRemap
            if !capsNeeded {
                lock.lock()
                held.setCapsLock(false)
                lock.unlock()
            }
            syncCapsLock(forceReapply: false)

            let total = newIndex.count
            configValidState = true
            configErrorState = nil
            activeBindingsState = total
            persistRuntimeStateLocked()

            let tapSuffix: String
            if let activeTap = currentTap, CGEvent.tapIsEnabled(tap: activeTap) {
                tapSuffix = " (event tap active)"
            } else {
                tapSuffix = ""
            }
            Log.daemon("config loaded: \(total) active shortcut(s)\(tapSuffix)")
            for shortcut in config.shortcuts where shortcut.enabled {
                var slots: [String] = []
                if let tap = shortcut.tap { slots.append("tap=\(Self.summarizeForLog(tap))") }
                if let doubleTap = shortcut.doubleTap { slots.append("doubleTap=\(Self.summarizeForLog(doubleTap))") }
                Log.daemon("  \(shortcut.keys.canonical) (\(Self.summarizeForLog(shortcut.displayName))): \(slots.joined(separator: " | "))")
            }
        } catch ConfigError.fileMissing {
            disarmAllBindingsOnInvalidConfig()
            configValidState = false
            configErrorState = "no configuration file at \(configURL.path)"
            activeBindingsState = 0
            persistRuntimeStateLocked()
            Log.daemon("config missing at \(configURL.path); disarmed active shortcuts")
        } catch ConfigError.insecureConfig(let detail) {
            disarmAllBindingsOnInvalidConfig()
            configValidState = false
            configErrorState = detail
            activeBindingsState = 0
            persistRuntimeStateLocked()
            Log.daemon("config rejected by StrictModes (\(detail)); disarmed active shortcuts")
            ShellRunner.notifyUser(
                category: "config-strictmodes",
                title: "Hotkeyd: Shortcuts Disarmed",
                body: "Config rejected by StrictModes: \(detail)"
            )
        } catch let strictError as StrictModes.StrictModesError {
            disarmAllBindingsOnInvalidConfig()
            configValidState = false
            configErrorState = strictError.localizedDescription
            activeBindingsState = 0
            persistRuntimeStateLocked()
            Log.daemon("config rejected by StrictModes (\(strictError.localizedDescription)); disarmed active shortcuts")
            ShellRunner.notifyUser(
                category: "config-strictmodes",
                title: "Hotkeyd: Shortcuts Disarmed",
                body: "Config rejected by StrictModes: \(strictError.localizedDescription)"
            )
        } catch {
            configValidState = false
            configErrorState = error.localizedDescription
            persistRuntimeStateLocked()
            Log.daemon("config error: \(error.localizedDescription)")
            ShellRunner.notifyUser(
                category: "config-error",
                title: "Hotkeyd: Invalid Config",
                body: error.localizedDescription
            )
        }
    }

    private func disarmAllBindingsOnInvalidConfig() {
        currentConfigState = Config()
        lock.lock()
        index = BindingIndex()
        peekConfigLocked = .default
        resetPeekStateLocked()
        detector.windowOverrides = [:]
        sequenceDetector.reset()
        cancelPendingKeyTapLocked()
        lastKeyTap = nil
        keyTapCooldownUntil.removeAll()
        held.setCapsLock(false)
        lock.unlock()
        applyPeekEffect(.hide)

        capsNeeded = false
        syncCapsLock(forceReapply: false)
    }

    private func scheduleDebouncedReload() {
        debouncedReloadItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        debouncedReloadItem = item
        controlQueue.asyncAfter(deadline: .now() + .milliseconds(125), execute: item)
    }

    private static func summarizeForLog(_ raw: String, limit: Int = 100) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// Watch the config file itself, not the directory. The config lives in $HOME now, and
    /// watching $HOME would reload on every unrelated file write.
    private func watchConfigDirectory() {
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        watchConfigFile()
    }

    private func watchConfigFile() {
        watcher?.cancel()
        watcher = nil

        var st = stat()
        guard lstat(configURL.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else {
            watchForFirstConfig()
            return
        }

        let descriptor = open(configURL.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            Log.daemon("could not watch \(configURL.path) directly; watching directory for replacement")
            watchForFirstConfig()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: controlQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // An atomic save replaces the inode, so the old descriptor is now watching a corpse.
            // Re-arm BEFORE reloading, and debounce 125ms so non-atomic truncate-then-write editors
            // do not cause transient empty-file reloads or Caps Lock churn.
            self.watchConfigFile()
            self.scheduleDebouncedReload()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        watcher = source
    }

    /// Before the first shortcut exists there is no file to watch; watch the directory until it
    /// appears, then switch to the file.
    private func watchForFirstConfig() {
        let directory = configURL.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: controlQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var st = stat()
            guard lstat(self.configURL.path, &st) == 0 else { return }
            self.watchConfigFile()
            self.scheduleDebouncedReload()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        watcher = source
    }

    /// Restore Caps Lock on the way out. launchd's `kickstart -k` and `bootout` send SIGTERM, so
    /// a normal stop never leaves the user without a Caps Lock key. A hard kill still can; the
    /// mapping is per-session and disappears at logout, and `hotkeyd caps off` is daemon-free.
    private func watchForTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: controlQueue)
        source.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            self.lock.lock()
            let wasRemapped = self.capsRemapped
            self.capsRemapped = false
            self.resetPeekStateLocked()
            self.lock.unlock()
            self.peekHoldWorkItem?.cancel()
            self.peekHoldWorkItem = nil
            self.peekBridge.shutdown()
            if wasRemapped {
                try? CapsLock.disable()
            }
            RuntimeState.remove(at: Paths.runtimeState, expectedPID: getpid())
            Log.daemon("terminating; caps lock restored: \(wasRemapped)")
            Log.flush()
            exit(0)
        }
        source.resume()
        terminationSource = source
    }

    /// Periodic health watchdog (coalesced at 2s ± 500ms leeway):
    /// 1. Detects runtime Accessibility revocation -> tears down dead tap, restores Caps Lock,
    ///    notifies user, and re-enters `waitForAccessibility()`.
    /// 2. Heals stuck Caps Lock LED state while remapped.
    private func startCapsWatchdog() {
        guard capsWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            if self.currentTap != nil && !AXIsProcessTrusted() {
                Log.daemon("accessibility permission revoked while running; pausing event tap")
                self.teardownTap()
                self.lock.lock()
                let wasRemapped = self.capsRemapped
                self.capsRemapped = false
                self.lock.unlock()
                if wasRemapped {
                    try? CapsLock.disable()
                    Log.daemon("caps lock restored after accessibility revocation")
                }
                self.tapActiveState = false
                self.tapNoteState = "Accessibility permission revoked"
                self.persistRuntimeStateLocked()
                ShellRunner.notifyUser(
                    category: "accessibility-revoked",
                    title: "Hotkeyd: Accessibility Revoked",
                    body: "Re-enable hotkeyd in System Settings > Privacy & Security > Accessibility."
                )
                self.waitForAccessibility()
                return
            }

            if let activePause = self.pauseState, activePause.isExpired() {
                self.syncPauseState(notifyOnExpiry: true)
            }

            guard self.pauseState == nil, self.isCapsRemapped, CapsLock.isCapsLockOn() else { return }
            guard Date().timeIntervalSince(self.lastCapsRecovery) > 2 else { return }
            self.lastCapsRecovery = Date()

            // `caps off` clears the mapping without telling the daemon. Confirm the key is still
            // remapped before touching state, otherwise we would fight a user who legitimately
            // turned Caps Lock on after restoring the key.
            guard CapsLock.state() == .enabled else {
                self.lock.lock()
                self.capsRemapped = false
                self.lock.unlock()
                self.persistRuntimeStateLocked()
                Log.daemon("caps remap is no longer active; watchdog standing down")
                return
            }

            let cleared = CapsLock.ensureCapsLockOff()
            Log.daemon("caps state was on while remapped; auto-reset \(cleared ? "ok" : "failed")")
        }
        timer.resume()
        capsWatchdog = timer
    }

    private var isCapsRemapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capsRemapped
    }

    /// Must be called on `controlQueue`.
    private func syncPauseState(notifyOnExpiry: Bool) {
        pauseResumeTimer?.cancel()
        pauseResumeTimer = nil

        let previousPause = pauseState
        guard let loaded = PauseState.load(from: Paths.pauseState) else {
            pauseState = nil
            lock.lock()
            let wasPaused = isPausedLocked
            isPausedLocked = false
            pauseResumeDateLocked = nil
            pauseExpiryDispatchedLocked = false
            lock.unlock()
            if wasPaused {
                Log.daemon("shortcuts resumed")
                syncCapsLock(forceReapply: false)
                persistRuntimeStateLocked()
            }
            return
        }

        if loaded.isExpired() {
            PauseState.clear(at: Paths.pauseState)
            pauseState = nil
            lock.lock()
            let wasPaused = isPausedLocked
            isPausedLocked = false
            pauseResumeDateLocked = nil
            pauseExpiryDispatchedLocked = false
            lock.unlock()
            if wasPaused || previousPause != nil {
                Log.daemon("pause timer expired; resuming shortcuts")
                syncCapsLock(forceReapply: false)
                persistRuntimeStateLocked()
                if notifyOnExpiry {
                    ShellRunner.notifyUser(
                        category: "pause-resumed",
                        title: "Hotkeyd",
                        body: "Shortcuts resumed automatically."
                    )
                }
            }
            return
        }

        pauseState = loaded
        lock.lock()
        let wasPaused = isPausedLocked
        isPausedLocked = true
        pauseResumeDateLocked = loaded.resumeDate
        pauseExpiryDispatchedLocked = false
        held.reset()
        detector = DoubleTapDetector(windowOverrides: detector.windowOverrides)
        sequenceDetector.reset()
        swallowedKeys.removeAll()
        cancelPendingKeyTapLocked()
        lastKeyTap = nil
        resetPeekStateLocked()
        lock.unlock()
        applyPeekEffect(.hide)

        if let resumeDate = loaded.resumeDate {
            let delay = max(0.1, resumeDate.timeIntervalSinceNow)
            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                self?.syncPauseState(notifyOnExpiry: true)
            }
            timer.resume()
            pauseResumeTimer = timer
        }

        if !wasPaused || previousPause != loaded {
            let untilNote = loaded.formattedRemaining().map { " for \($0)" } ?? " indefinitely"
            let reasonNote = loaded.reason.map { " (reason: \($0))" } ?? ""
            Log.daemon("shortcuts paused\(untilNote)\(reasonNote)")
        }
        syncCapsLock(forceReapply: false)
        persistRuntimeStateLocked()
    }

    /// Must be called on `controlQueue`.
    private func syncCapsLock(forceReapply: Bool) {
        guard currentTap != nil else { return }
        if capsNeeded && pauseState == nil {
            if !forceReapply && isCapsRemapped {
                return
            }
            do {
                let wasRemapped = isCapsRemapped
                try CapsLock.enable(forceReapply: forceReapply)
                lock.lock()
                capsRemapped = true
                lock.unlock()
                persistRuntimeStateLocked()
                if !wasRemapped {
                    Log.daemon("caps lock remapped to F18; capsLock binding is live")
                }
            } catch {
                lock.lock()
                capsRemapped = false
                lock.unlock()
                persistRuntimeStateLocked()
                Log.daemon("caps lock remap failed: \(error.localizedDescription)")
                ShellRunner.notifyUser(
                    category: "caps-lock-error",
                    title: "Hotkeyd: Caps Lock Remap Failed",
                    body: error.localizedDescription
                )
            }
        } else {
            let wasRemapped = isCapsRemapped
            let currentlyEnabled = CapsLock.state() == .enabled
            guard wasRemapped || currentlyEnabled else { return }
            if currentlyEnabled {
                do {
                    try CapsLock.disable()
                    Log.daemon("caps lock restored")
                } catch {
                    // Keep `capsRemapped = true` while HID remap is still active so raw F18
                    // continues to be swallowed instead of leaking into focused apps/passwords.
                    Log.daemon("could not restore caps lock: \(error.localizedDescription)")
                    return
                }
            }
            lock.lock()
            capsRemapped = false
            lock.unlock()
            persistRuntimeStateLocked()
        }
    }

    private func watchForReloadSignal() {
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: controlQueue)
        source.setEventHandler { [weak self] in
            Log.daemon("SIGHUP received; reloading configuration")
            self?.debouncedReloadItem?.cancel()
            self?.reload()
        }
        source.resume()
        signalSource = source
    }

    // MARK: - Peek Overlay State Machine & Signal

    /// Must be called with `lock` held.
    private func resetPeekStateLocked() {
        peekModeLocked = .idle
        peekArmingTriggerLocked = nil
        peekPinnedWaitForClearLocked = false
        peekGenerationLocked &+= 1
    }

    /// Must be called with `lock` held.
    private func togglePinnedPeekLocked(waitForModifierClear: Bool = false) -> PeekEffect {
        peekArmingTriggerLocked = nil
        peekGenerationLocked &+= 1
        if peekModeLocked == .pinned {
            peekModeLocked = .idle
            peekPinnedWaitForClearLocked = false
            return .hide
        }
        peekModeLocked = .pinned
        peekPinnedWaitForClearLocked = waitForModifierClear
        return .showPinned
    }

    /// Must be called with `lock` held.
    private func cancelOrHidePeekLocked() -> PeekEffect {
        if peekModeLocked != .idle {
            peekModeLocked = .idle
            peekArmingTriggerLocked = nil
            peekPinnedWaitForClearLocked = false
            peekGenerationLocked &+= 1
            return .hide
        }
        if peekArmingTriggerLocked != nil {
            peekArmingTriggerLocked = nil
            peekGenerationLocked &+= 1
            return .cancelPending
        }
        return .none
    }

    /// Must be called with `lock` held.
    private func updatePeekForModifiersLocked(heldKeys: Set<Modifier>) -> PeekEffect {
        switch peekModeLocked {
        case .pinned:
            if peekPinnedWaitForClearLocked {
                if heldKeys.isEmpty {
                    peekPinnedWaitForClearLocked = false
                }
                return .none
            }
            return .updatePinned(held: heldKeys)

        case .hold(let trigger):
            let stillHeld = heldKeys.contains { PeekModel.modifier($0, satisfies: trigger) }
            if stillHeld && (trigger != .capsLock || capsRemapped) {
                return .none
            }
            peekModeLocked = .idle
            peekArmingTriggerLocked = nil
            peekGenerationLocked &+= 1
            return .hide

        case .idle:
            if peekConfigLocked.enabled,
               heldKeys.count == 1,
               let single = heldKeys.first,
               peekConfigLocked.matchesTrigger(single, capsLockRemapped: capsRemapped) {
                if peekArmingTriggerLocked == single {
                    return .none
                }
                peekArmingTriggerLocked = single
                peekGenerationLocked &+= 1
                return .arm(
                    trigger: single,
                    delayMilliseconds: peekConfigLocked.delayMilliseconds,
                    generation: peekGenerationLocked
                )
            }
            if peekArmingTriggerLocked != nil {
                peekArmingTriggerLocked = nil
                peekGenerationLocked &+= 1
                return .cancelPending
            }
            return .none
        }
    }

    /// Must be called strictly on `controlQueue` (never under `Daemon.lock`).
    private func resetPeekModeFromControlQueue() {
        lock.lock()
        resetPeekStateLocked()
        lock.unlock()
    }

    /// Must be called strictly on `controlQueue` (never under `Daemon.lock`).
    private func applyPeekEffect(_ effect: PeekEffect) {
        switch effect {
        case .none:
            return

        case .cancelPending:
            peekHoldWorkItem?.cancel()
            peekHoldWorkItem = nil

        case .hide:
            peekHoldWorkItem?.cancel()
            peekHoldWorkItem = nil
            peekBridge.hide()

        case .showPinned:
            peekHoldWorkItem?.cancel()
            peekHoldWorkItem = nil
            guard pauseState == nil, configValidState, !IsSecureEventInputEnabled() else {
                resetPeekModeFromControlQueue()
                peekBridge.hide()
                return
            }
            let snapshot = PeekModel.buildSnapshot(
                from: currentConfigState,
                mode: .pinned,
                heldModifiers: []
            )
            if !peekBridge.show(snapshot) {
                resetPeekModeFromControlQueue()
            }

        case .toggleSearch:
            peekHoldWorkItem?.cancel()
            peekHoldWorkItem = nil
            guard pauseState == nil, configValidState, !IsSecureEventInputEnabled() else {
                resetPeekModeFromControlQueue()
                peekBridge.hide()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSearchToggleUptime >= Self.peekSignalMinIntervalSeconds else {
                return
            }
            lastSearchToggleUptime = now
            let searchSnapshot = buildSearchSnapshotCached()
            _ = peekBridge.toggleSearch(searchSnapshot)

        case .updatePinned(let heldKeys):
            guard pauseState == nil, configValidState, !IsSecureEventInputEnabled() else {
                resetPeekModeFromControlQueue()
                peekBridge.hide()
                return
            }
            let snapshot = PeekModel.buildSnapshot(
                from: currentConfigState,
                mode: .pinned,
                heldModifiers: heldKeys
            )
            if !peekBridge.show(snapshot) {
                resetPeekModeFromControlQueue()
            }

        case .arm(let trigger, let delayMilliseconds, let generation):
            peekHoldWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pauseState == nil, self.configValidState, !IsSecureEventInputEnabled() else {
                    return
                }
                self.lock.lock()
                guard self.peekGenerationLocked == generation,
                      self.peekArmingTriggerLocked == trigger,
                      self.peekModeLocked == .idle,
                      !self.isPausedLocked,
                      !self.wasInSecureInput,
                      self.peekConfigLocked.enabled,
                      (trigger != .capsLock || self.capsRemapped),
                      self.held.keys.contains(where: { PeekModel.modifier($0, satisfies: trigger) }) else {
                    self.lock.unlock()
                    return
                }
                self.peekArmingTriggerLocked = nil
                self.peekModeLocked = .hold(trigger)
                self.lock.unlock()

                let snapshot = PeekModel.buildSnapshot(
                    from: self.currentConfigState,
                    mode: .hold,
                    heldModifiers: [trigger]
                )
                if !self.peekBridge.show(snapshot) {
                    self.resetPeekModeFromControlQueue()
                }
            }
            peekHoldWorkItem = item
            controlQueue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds), execute: item)
        }
    }

    /// Builds a frequency-ranked Search HUD snapshot on `controlQueue`, caching `actions.log`
    /// usage tallies by `(dev, ino, mtime, size)` so repeated toggles avoid re-reading up to 12 MiB
    /// of logs on the daemon's control queue.
    private func buildSearchSnapshotCached() -> PeekSearchSnapshot {
        let fingerprint = StatsAnalyzer.logsFingerprint(logsDirectory: Paths.logs)
        if fingerprint != cachedSearchUsageFingerprint {
            cachedSearchUsageCounts = StatsAnalyzer.loadShortcutCounts(logsDirectory: Paths.logs)
            cachedSearchUsageFingerprint = fingerprint
        }
        return PeekSearchBuilder.buildSnapshot(
            from: currentConfigState,
            logsDirectory: nil,
            cachedUsageCounts: cachedSearchUsageCounts
        )
    }

    private func watchForPeekToggleSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: controlQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastPeekSignalUptime >= Self.peekSignalMinIntervalSeconds else {
                return
            }
            self.lastPeekSignalUptime = now
            guard self.pauseState == nil, self.currentTap != nil, !IsSecureEventInputEnabled() else {
                Log.daemon("SIGUSR1 peek toggle ignored (paused, tap inactive, or Secure Input active)")
                return
            }
            guard self.configValidState else {
                Log.daemon("SIGUSR1 peek toggle ignored (configuration invalid)")
                return
            }
            guard self.currentConfigState.peek.enabled else {
                Log.daemon("SIGUSR1 peek toggle ignored (peek is disabled)")
                return
            }
            self.peekHoldWorkItem?.cancel()
            self.peekHoldWorkItem = nil

            self.lock.lock()
            self.peekArmingTriggerLocked = nil
            self.peekPinnedWaitForClearLocked = false
            self.peekGenerationLocked &+= 1
            let shouldShow: Bool
            if self.peekModeLocked == .pinned {
                self.peekModeLocked = .idle
                shouldShow = false
            } else {
                self.peekModeLocked = .pinned
                shouldShow = true
            }
            self.lock.unlock()

            if shouldShow {
                let snapshot = PeekModel.buildSnapshot(
                    from: self.currentConfigState,
                    mode: .pinned,
                    heldModifiers: []
                )
                if !self.peekBridge.show(snapshot) {
                    self.resetPeekModeFromControlQueue()
                }
            } else {
                self.peekBridge.hide()
            }
        }
        source.resume()
        peekToggleSignalSource = source
    }

    private func watchForPeekSearchSignal() {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: controlQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastSearchToggleUptime >= Self.peekSignalMinIntervalSeconds else {
                return
            }
            self.lastSearchToggleUptime = now
            guard self.pauseState == nil, self.currentTap != nil, !IsSecureEventInputEnabled() else {
                Log.daemon("SIGUSR2 peek search toggle ignored (paused, tap inactive, or Secure Input active)")
                return
            }
            guard self.configValidState else {
                Log.daemon("SIGUSR2 peek search toggle ignored (configuration invalid)")
                return
            }
            guard self.currentConfigState.peek.enabled else {
                Log.daemon("SIGUSR2 peek search toggle ignored (peek is disabled)")
                return
            }
            self.peekHoldWorkItem?.cancel()
            self.peekHoldWorkItem = nil

            self.lock.lock()
            self.resetPeekStateLocked()
            self.lock.unlock()

            let searchSnapshot = self.buildSearchSnapshotCached()
            self.peekBridge.toggleSearch(searchSnapshot)
        }
        source.resume()
        peekSearchSignalSource = source
    }
}
