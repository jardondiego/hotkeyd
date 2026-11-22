import AppKit
import Darwin
import Foundation

@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func hotkeyd_responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ disclaim: CInt
) -> CInt

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func hotkeyd_responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func hotkeyd_posix_spawn_file_actions_addchdir_np(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ path: UnsafePointer<CChar>
) -> CInt

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
    public let durationMilliseconds: Int

    public init(exitCode: Int32, timedOut: Bool, stdout: String, stderr: String, durationMilliseconds: Int) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderr = stderr
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum ShellRunner {
    public static let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    public static let privilegedPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let maxCapturedBytes = 4096
    public static let maxConcurrentActions = 8
    public static let postExitPipeDrainGraceSeconds: Double = 0.25
    private static let activeLock = NSLock()
    private static var inFlightCount = 0
    private static var _disallowAccessibilityDelegation = false
    private static var loggedSelectionDisabled = false

    private static let appCacheLock = NSLock()
    private static var appURLCache: [String: (url: URL, cachedAt: CFAbsoluteTime)] = [:]
    private static let appCacheTTLSeconds: Double = 30.0

    private static let notifyLock = NSLock()
    private static var lastNotifyByCategory: [String: CFAbsoluteTime] = [:]

    /// Clears the in-process application bundle resolution cache (primarily for tests).
    public static func clearApplicationURLCache() {
        appCacheLock.lock()
        appURLCache.removeAll()
        appCacheLock.unlock()
    }

    /// Posts a rate-limited, TCC-disclaimed macOS notification for critical daemon errors (no-op
    /// while `HOTKEYD_HOME` is set so tests and sandboxes never trigger desktop alerts).
    /// Passes title and body via `argv` (never interpolated into AppleScript source) and executes
    /// via `runExecutable` so every `osascript` child is bounded by a timeout and cleanly reaped.
    public static func notifyUser(
        category: String,
        title: String,
        body: String,
        cooldownSeconds: Double = 30.0
    ) {
        guard !Paths.isEnvironmentOverrideActive else { return }
        let now = CFAbsoluteTimeGetCurrent()
        notifyLock.lock()
        if let last = lastNotifyByCategory[category], now - last < cooldownSeconds {
            notifyLock.unlock()
            return
        }
        if lastNotifyByCategory.count >= 64 {
            lastNotifyByCategory = lastNotifyByCategory.filter { now - $0.value < max(cooldownSeconds, 300.0) }
            if lastNotifyByCategory.count >= 64 {
                lastNotifyByCategory.removeAll()
            }
        }
        lastNotifyByCategory[category] = now
        notifyLock.unlock()

        let cleanTitle = Log.sanitizeMessage(title)
        let cleanBody = Log.sanitizeMessage(body)
        DispatchQueue.global(qos: .utility).async {
            _ = runExecutable(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "/usr/bin/osascript",
                    "-e", "on run argv",
                    "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                    "-e", "end run",
                    "--",
                    cleanTitle,
                    cleanBody
                ],
                environment: scrubbedEnvironment(allowAccessibility: false),
                workingDirectory: Paths.realHomeDirectory.path,
                timeoutMilliseconds: 5_000,
                disclaimResponsibility: true,
                started: Date()
            )
        }
    }

    /// Returns `true` when `action` executes natively via `NSWorkspace` (app launch or web URL)
    /// without spawning `/bin/zsh`, so it should bypass the shell worker concurrency cap.
    public static func isFastNativeAction(_ action: Action, allowAccessibility: Bool) -> Bool {
        let inheritTCC = canDelegateAccessibility(allowAccessibility)
        switch action {
        case .app, .url:
            return true
        case .openPath:
            return false
        case .shell(let command, let cwd, _):
            let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !inheritTCC,
                  !SelectionReader.commandUsesSelectedText(command),
                  trimmedCwd.isEmpty,
                  let fast = Action.migratedFromShellCommand(command) else {
                return false
            }
            switch fast {
            case .app, .url:
                return true
            case .openPath, .shell:
                return false
            }
        }
    }

    /// Set by `hotkeyd daemon run` when started with `--allow-adhoc` or a non-default `--config`
    /// path so untrusted/ad-hoc daemon invocations can never delegate Accessibility TCC to children.
    public static var disallowAccessibilityDelegation: Bool {
        get {
            activeLock.lock()
            defer { activeLock.unlock() }
            return _disallowAccessibilityDelegation
        }
        set {
            activeLock.lock()
            _disallowAccessibilityDelegation = newValue
            activeLock.unlock()
        }
    }

    /// Returns `true` only when `allowAccessibility` is requested AND neither `HOTKEYD_HOME` nor
    /// `disallowAccessibilityDelegation` is active.
    public static func canDelegateAccessibility(_ allowAccessibility: Bool) -> Bool {
        allowAccessibility && !Paths.isEnvironmentOverrideActive && !disallowAccessibilityDelegation
    }

    public static var currentInFlightCount: Int {
        activeLock.lock()
        defer { activeLock.unlock() }
        return inFlightCount
    }

    /// Returns the macOS TCC responsible PID for `pid` (equals `pid` when responsibility is disclaimed).
    public static func responsiblePID(for pid: pid_t) -> pid_t {
        guard pid > 0 else { return -1 }
        return hotkeyd_responsibility_get_pid_responsible_for_pid(pid)
    }

    public struct SpawnError: Error, Equatable {
        public let errnoCode: Int32
        public init(_ errnoCode: Int32) { self.errnoCode = errnoCode }
    }

    /// Pure-Swift `posix_spawn` wrapper with kernel-level TCC responsibility disclaim, working
    /// directory configuration, optional process-group isolation (`pgid == pid`),
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, and reset signal dispositions/mask.
    public static func spawnProcess(
        executablePath: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String?,
        stdinFD: Int32 = -1,
        stdoutFD: Int32 = -1,
        stderrFD: Int32 = -1,
        disclaimResponsibility: Bool = true,
        setProcessGroup: Bool = true,
        inheritStandardIO: Bool = false
    ) -> Result<pid_t, SpawnError> {
        guard !executablePath.isEmpty,
              !executablePath.contains("\0"),
              !arguments.isEmpty,
              !arguments.contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.contains("\0") }),
              !(workingDirectory?.contains("\0") ?? false) else {
            return .failure(SpawnError(EINVAL))
        }

        var attr: posix_spawnattr_t?
        let initAttrRC = posix_spawnattr_init(&attr)
        guard initAttrRC == 0 else {
            return .failure(SpawnError(initAttrRC))
        }
        defer { posix_spawnattr_destroy(&attr) }

        var actions: posix_spawn_file_actions_t?
        let initActionsRC = posix_spawn_file_actions_init(&actions)
        guard initActionsRC == 0 else {
            return .failure(SpawnError(initActionsRC))
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        if disclaimResponsibility {
            let disclaimRC = hotkeyd_responsibility_spawnattrs_setdisclaim(&attr, 1)
            guard disclaimRC == 0 else {
                return .failure(SpawnError(disclaimRC))
            }
        }

        var allSignals = sigset_t()
        var noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)

        var spawnFlags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        if setProcessGroup {
            spawnFlags |= Int16(POSIX_SPAWN_SETPGROUP)
        }

        var rc = posix_spawnattr_setsigdefault(&attr, &allSignals)
        if rc == 0 {
            rc = posix_spawnattr_setsigmask(&attr, &noSignals)
        }
        if rc == 0 && setProcessGroup {
            rc = posix_spawnattr_setpgroup(&attr, 0)
        }
        if rc == 0 {
            rc = posix_spawnattr_setflags(&attr, spawnFlags)
        }
        guard rc == 0 else {
            return .failure(SpawnError(rc))
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            rc = workingDirectory.withCString { chdirPtr in
                hotkeyd_posix_spawn_file_actions_addchdir_np(&actions, chdirPtr)
            }
            guard rc == 0 else {
                return .failure(SpawnError(rc))
            }
        }

        if stdinFD >= 0 {
            rc = posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO)
        } else if inheritStandardIO {
            rc = posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO)
        } else {
            rc = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        guard rc == 0 else {
            return .failure(SpawnError(rc))
        }

        if stdoutFD >= 0 {
            rc = posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
        } else if inheritStandardIO {
            rc = posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO)
        } else {
            rc = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        }
        guard rc == 0 else {
            return .failure(SpawnError(rc))
        }

        if stderrFD >= 0 {
            rc = posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO)
        } else if inheritStandardIO {
            rc = posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        } else {
            rc = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        guard rc == 0 else {
            return .failure(SpawnError(rc))
        }

        var childPID: pid_t = -1
        let spawnRC = withCStrings(arguments) { argvPtr in
            withCStrings(environment) { envpPtr in
                executablePath.withCString { execPtr in
                    posix_spawn(&childPID, execPtr, &actions, &attr, argvPtr, envpPtr)
                }
            }
        }
        guard spawnRC == 0, childPID > 0 else {
            return .failure(SpawnError(spawnRC == 0 ? ECHILD : spawnRC))
        }
        return .success(childPID)
    }

    /// Runs a shortcut's action off the tap thread so a slow command can never delay the next keypress.
    public static func spawn(
        shortcut: Shortcut,
        selectionTarget: SelectionReader.TargetApp? = nil
    ) {
        spawn(
            name: shortcut.displayName,
            action: shortcut.activeAction,
            allowAccessibility: shortcut.allowAccessibility,
            selectionTarget: selectionTarget
        )
    }

    /// Runs the action off the tap thread so a slow command can never delay the next keypress,
    /// enforcing `maxConcurrentActions` on shell workers so XNU's constrained workqueue pool is
    /// never exhausted while allowing fast native `NSWorkspace` launches to run unblocked.
    public static func spawn(
        name: String,
        action: Action,
        allowAccessibility: Bool = false,
        selectionTarget: SelectionReader.TargetApp? = nil
    ) {
        if isFastNativeAction(action, allowAccessibility: allowAccessibility) {
            DispatchQueue.global(qos: .userInteractive).async {
                let result = execute(
                    action: action,
                    allowAccessibility: allowAccessibility,
                    selectionTarget: selectionTarget
                )
                logAndNotifyActionOutcome(name: name, action: action, result: result)
            }
            return
        }

        activeLock.lock()
        guard inFlightCount < maxConcurrentActions else {
            activeLock.unlock()
            Log.action(
                "shortcut=\(singleLine(name)) dropped (max \(maxConcurrentActions) concurrent actions in flight)"
            )
            notifyUser(
                category: "worker-pool-full",
                title: "Hotkeyd",
                body: "Shortcut '\(singleLine(name, limit: 60))' dropped: \(maxConcurrentActions) actions already running."
            )
            return
        }
        inFlightCount += 1
        activeLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                activeLock.lock()
                inFlightCount = max(0, inFlightCount - 1)
                activeLock.unlock()
            }
            let result = execute(
                action: action,
                allowAccessibility: allowAccessibility,
                selectionTarget: selectionTarget
            )
            logAndNotifyActionOutcome(name: name, action: action, result: result)
        }
    }

    private static func logAndNotifyActionOutcome(
        name: String,
        action: Action,
        result: ShellResult
    ) {
        let outcome = result.timedOut ? "timeout" : "exit=\(result.exitCode)"
        Log.action(
            "shortcut=\(singleLine(name)) \(outcome) \(result.durationMilliseconds)ms action=\(singleLine(action.summary))"
        )
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            Log.action("shortcut=\(singleLine(name)) stderr=\(singleLine(trimmedStderr))")
        }
        if result.timedOut {
            notifyUser(
                category: "action-timeout:\(name)",
                title: "Hotkeyd: Shortcut Timed Out",
                body: "'\(singleLine(name, limit: 60))' exceeded its timeout (\(result.durationMilliseconds)ms)."
            )
        } else if result.exitCode < 0 || trimmedStderr.contains("could not be found") {
            notifyUser(
                category: "action-launch-error:\(name)",
                title: "Hotkeyd: Shortcut Failed",
                body: "'\(singleLine(name, limit: 50))': \(singleLine(trimmedStderr, limit: 120))"
            )
        }
    }

    /// Starts a shortcut action synchronously in detached mode for `hotkeyd run <name>` (without
    /// `--wait`) so the child process is already spawned before the CLI exits.
    public static func dispatchDetached(
        shortcut: Shortcut,
        selectionTarget: SelectionReader.TargetApp? = nil
    ) throws {
        let action = shortcut.activeAction
        let inheritTCC = canDelegateAccessibility(shortcut.allowAccessibility)
        switch action {
        case .shell(let command, let cwd, _):
            let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usesSelectedText = SelectionReader.commandUsesSelectedText(command)
            if !inheritTCC, !usesSelectedText, trimmedCwd.isEmpty,
               let fast = Action.migratedFromShellCommand(command) {
                switch fast {
                case .app, .url:
                    let result = execute(action: fast, allowAccessibility: false)
                    if result.exitCode != 0 {
                        throw SpawnError(EIO)
                    }
                    return
                case .openPath(let rawPath):
                    if let dirResult = runOpenDirectory(rawPath) {
                        if dirResult.exitCode != 0 {
                            throw SpawnError(EIO)
                        }
                        return
                    }
                case .shell:
                    break
                }
            }
            let workingDirectory: String
            if !trimmedCwd.isEmpty {
                guard let resolved = Paths.resolveWorkingDirectory(trimmedCwd) else {
                    throw SpawnError(EINVAL)
                }
                if inheritTCC {
                    guard (try? StrictModes.verifySecurePath(resolved, expectRegularFile: false)) != nil else {
                        throw SpawnError(EACCES)
                    }
                }
                workingDirectory = resolved
            } else {
                workingDirectory = Paths.realHomeDirectory.path
            }
            let resolvedSelection: SelectionReader.SelectionResult?
            if usesSelectedText {
                let canReadSelection = !Paths.isEnvironmentOverrideActive && !disallowAccessibilityDelegation
                if canReadSelection {
                    resolvedSelection = SelectionReader.readSelectedTextResult(target: selectionTarget)
                } else {
                    logSelectionDisabledOnce()
                    resolvedSelection = SelectionReader.SelectionResult(text: "", status: .disabled)
                }
            } else {
                resolvedSelection = nil
            }
            let outcome = spawnProcess(
                executablePath: "/bin/zsh",
                arguments: ["/bin/zsh", "-fc", command],
                environment: scrubbedEnvironment(
                    allowAccessibility: shortcut.allowAccessibility,
                    selectedText: resolvedSelection?.text,
                    selectedTextStatus: resolvedSelection?.status
                ),
                workingDirectory: workingDirectory,
                stdinFD: -1,
                stdoutFD: -1,
                stderrFD: -1,
                disclaimResponsibility: !inheritTCC
            )
            if case .failure(let error) = outcome {
                throw error
            }
        case .app, .url, .openPath:
            let result = execute(
                action: action,
                allowAccessibility: inheritTCC
            )
            if result.exitCode != 0 {
                throw SpawnError(EIO)
            }
        }
    }

    /// Synchronous execution of any `Action` (`.shell`, `.app`, `.url`, `.openPath`), automatically
    /// routing simple metacharacter-free `open -a <App>`, `open <http(s)://...>`, and `open <dir>`
    /// commands through `NSWorkspace` without spawning `/bin/zsh`.
    public static func execute(
        action: Action,
        allowAccessibility: Bool = false,
        selectionTarget: SelectionReader.TargetApp? = nil
    ) -> ShellResult {
        let inheritTCC = canDelegateAccessibility(allowAccessibility)
        switch action {
        case .shell(let command, let cwd, let timeout):
            let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !inheritTCC, !SelectionReader.commandUsesSelectedText(command), trimmedCwd.isEmpty,
               let fast = Action.migratedFromShellCommand(command) {
                switch fast {
                case .app(let target, let arguments):
                    return runApp(target: target, arguments: arguments)
                case .url(let rawURL):
                    return runURL(rawURL)
                case .openPath(let rawPath):
                    if let dirResult = runOpenDirectory(rawPath) {
                        return dirResult
                    }
                case .shell:
                    break
                }
            }
            return run(
                command: command,
                cwd: cwd,
                timeoutMilliseconds: timeout ?? 30_000,
                allowAccessibility: allowAccessibility,
                selectionTarget: selectionTarget
            )
        case .app(let target, let arguments):
            return runApp(target: target, arguments: arguments)
        case .url(let rawURL):
            return runURL(rawURL)
        case .openPath(let rawPath):
            if let dirResult = runOpenDirectory(rawPath) {
                return dirResult
            }
            let started = Date()
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("\0"),
                  !trimmed.contains("\n"),
                  !trimmed.contains("\r"),
                  !trimmed.hasPrefix("-") else {
                return ShellResult(
                    exitCode: 1,
                    timedOut: false,
                    stdout: "",
                    stderr: "refusing invalid path '\(rawPath)'",
                    durationMilliseconds: 0
                )
            }
            let expanded = Paths.expandTilde(trimmed)
            return runExecutable(
                executablePath: "/usr/bin/open",
                arguments: ["/usr/bin/open", "--", expanded],
                environment: scrubbedEnvironment(allowAccessibility: false),
                workingDirectory: Paths.realHomeDirectory.path,
                timeoutMilliseconds: 30_000,
                disclaimResponsibility: true,
                started: started
            )
        }
    }

    /// Constructs the scrubbed environment array for child processes.
    public static func scrubbedEnvironment(
        allowAccessibility: Bool = false,
        selectedText: String? = nil,
        selectedTextStatus: SelectionReader.SelectionStatus? = nil
    ) -> [String] {
        let home = Paths.realHomeDirectory.path
        let user = Paths.realUserName
        let path = allowAccessibility ? privilegedPath : standardPath
        let lang = validatedLocale()
        var env = [
            "HOME=\(home)",
            "USER=\(user)",
            "LOGNAME=\(user)",
            "PATH=\(path)",
            "LANG=\(lang)",
            "TERM=dumb",
            "HOTKEYD=1"
        ]
        if let selectedText {
            let sanitized = SelectionReader.sanitize(selectedText)
            let status = selectedTextStatus ?? (sanitized.isEmpty ? .empty : .ok)
            env.append("SELECTED_TEXT=\(sanitized)")
            env.append("SELECTED_TEXT_STATUS=\(status.rawValue)")
        }
        return env
    }

    private static func logSelectionDisabledOnce() {
        activeLock.lock()
        let shouldLog = !loggedSelectionDisabled
        loggedSelectionDisabled = true
        activeLock.unlock()
        if shouldLog {
            Log.daemon("SELECTED_TEXT disabled while HOTKEYD_HOME or --allow-adhoc is active")
        }
    }

    /// Synchronous `/bin/zsh -fc` execution with TCC responsibility disclaimed by default.
    public static func run(
        command: String,
        cwd: String?,
        timeoutMilliseconds: Int = 30_000,
        allowAccessibility: Bool = false,
        selectedTextOverride: String? = nil,
        selectionTarget: SelectionReader.TargetApp? = nil
    ) -> ShellResult {
        let started = Date()
        let inheritTCC = canDelegateAccessibility(allowAccessibility)

        let workingDirectory: String
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = Paths.resolveWorkingDirectory(cwd) else {
                return ShellResult(
                    exitCode: -1,
                    timedOut: false,
                    stdout: "",
                    stderr: "invalid working directory '\(cwd)'; expected an absolute path or '~'",
                    durationMilliseconds: 0
                )
            }
            if inheritTCC {
                do {
                    try StrictModes.verifySecurePath(resolved, expectRegularFile: false)
                } catch {
                    return ShellResult(
                        exitCode: -1,
                        timedOut: false,
                        stdout: "",
                        stderr: "refusing insecure working directory '\(resolved)' for privileged action: \(error.localizedDescription)",
                        durationMilliseconds: 0
                    )
                }
            }
            workingDirectory = resolved
        } else {
            workingDirectory = Paths.realHomeDirectory.path
        }

        let resolvedSelectedText: String?
        let resolvedSelectedStatus: SelectionReader.SelectionStatus?
        if let selectedTextOverride {
            let sanitized = SelectionReader.sanitize(selectedTextOverride)
            resolvedSelectedText = sanitized
            resolvedSelectedStatus = sanitized.isEmpty ? .empty : .ok
        } else if SelectionReader.commandUsesSelectedText(command) {
            let canReadSelection = !Paths.isEnvironmentOverrideActive && !disallowAccessibilityDelegation
            if canReadSelection {
                let result = SelectionReader.readSelectedTextResult(target: selectionTarget)
                resolvedSelectedText = result.text
                resolvedSelectedStatus = result.status
            } else {
                logSelectionDisabledOnce()
                resolvedSelectedText = ""
                resolvedSelectedStatus = .disabled
            }
        } else {
            resolvedSelectedText = nil
            resolvedSelectedStatus = nil
        }

        return runExecutable(
            executablePath: "/bin/zsh",
            arguments: ["/bin/zsh", "-fc", command],
            environment: scrubbedEnvironment(
                allowAccessibility: allowAccessibility,
                selectedText: resolvedSelectedText,
                selectedTextStatus: resolvedSelectedStatus
            ),
            workingDirectory: workingDirectory,
            timeoutMilliseconds: timeoutMilliseconds,
            disclaimResponsibility: !inheritTCC,
            started: started
        )
    }

    /// Runs a fixed system tool (`/usr/bin/hidutil`, `/bin/launchctl`, etc.) directly via
    /// `posix_spawn` with scrubbed environment, disclaimed TCC responsibility, bounded pipes,
    /// and a hard timeout.
    public static func runSystemTool(
        executablePath: String,
        arguments: [String],
        timeoutMilliseconds: Int = 5_000
    ) -> ShellResult {
        runExecutable(
            executablePath: executablePath,
            arguments: arguments,
            environment: scrubbedEnvironment(allowAccessibility: true),
            workingDirectory: "/",
            timeoutMilliseconds: timeoutMilliseconds,
            disclaimResponsibility: true,
            started: Date()
        )
    }

    private static func runExecutable(
        executablePath: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String,
        timeoutMilliseconds: Int,
        disclaimResponsibility: Bool,
        started: Date
    ) -> ShellResult {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            return ShellResult(
                exitCode: -1,
                timedOut: false,
                stdout: "",
                stderr: "could not create stdout pipe",
                durationMilliseconds: 0
            )
        }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            return ShellResult(
                exitCode: -1,
                timedOut: false,
                stdout: "",
                stderr: "could not create stderr pipe",
                durationMilliseconds: 0
            )
        }

        _ = fcntl(stdoutPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe[0], F_SETNOSIGPIPE, 1)
        _ = fcntl(stderrPipe[0], F_SETNOSIGPIPE, 1)
        _ = fcntl(stdoutPipe[0], F_SETFL, fcntl(stdoutPipe[0], F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderrPipe[0], F_SETFL, fcntl(stderrPipe[0], F_GETFL) | O_NONBLOCK)

        let spawnOutcome = spawnProcess(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            stdinFD: -1,
            stdoutFD: stdoutPipe[1],
            stderrFD: stderrPipe[1],
            disclaimResponsibility: disclaimResponsibility
        )

        // Parent never writes to the child's stdout/stderr pipes.
        close(stdoutPipe[1])
        close(stderrPipe[1])

        let childPID: pid_t
        switch spawnOutcome {
        case .success(let pid):
            childPID = pid
        case .failure(let spawnError):
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return ShellResult(
                exitCode: -1,
                timedOut: false,
                stdout: "",
                stderr: "could not start \(executablePath): \(String(cString: strerror(spawnError.errnoCode)))",
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
            )
        }

        final class PipeBuffer: @unchecked Sendable {
            var value = ""
        }
        let drainSignal = PipeDrainSignal(graceSeconds: postExitPipeDrainGraceSeconds)
        let stdoutBox = PipeBuffer()
        let stderrBox = PipeBuffer()
        let readGroup = DispatchGroup()

        let outFD = stdoutPipe[0]
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.value = readBoundedPipe(fd: outFD, drainSignal: drainSignal)
            close(outFD)
            readGroup.leave()
        }

        let errFD = stderrPipe[0]
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.value = readBoundedPipe(fd: errFD, drainSignal: drainSignal)
            close(errFD)
            readGroup.leave()
        }

        let timeout = max(1, min(timeoutMilliseconds, 600_000))
        final class TimeoutState: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var timedOut = false
        }
        let timeoutState = TimeoutState()

        let killer = DispatchWorkItem {
            timeoutState.lock.lock()
            if timeoutState.finished {
                timeoutState.lock.unlock()
                return
            }
            timeoutState.timedOut = true
            _ = kill(-childPID, SIGTERM)
            _ = kill(childPID, SIGTERM)
            timeoutState.lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) {
                timeoutState.lock.lock()
                if !timeoutState.finished {
                    _ = kill(-childPID, SIGKILL)
                    _ = kill(childPID, SIGKILL)
                }
                timeoutState.lock.unlock()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(timeout),
            execute: killer
        )

        // Wait for child exit WITHOUT reaping (`WNOWAIT`) so `childPID` remains pinned in XNU's PID
        // table until `timeoutState.finished` is set under lock — preventing PID-reuse signal races.
        var sigInfo = siginfo_t()
        while true {
            let rc = waitid(P_PID, id_t(childPID), &sigInfo, WEXITED | WNOWAIT)
            if rc == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            break
        }

        timeoutState.lock.lock()
        timeoutState.finished = true
        let didTimeout = timeoutState.timedOut
        if didTimeout {
            // Ensure no backgrounded grandchild holds pipe write ends open after timeout.
            _ = kill(-childPID, SIGKILL)
        }
        timeoutState.lock.unlock()
        killer.cancel()

        var rawStatus: Int32 = 0
        while true {
            let waited = waitpid(childPID, &rawStatus, 0)
            if waited == childPID {
                break
            }
            if waited < 0 && errno == EINTR {
                continue
            }
            break
        }

        // Bound pipe draining once the direct child exits so a detached grandchild that inherited
        // stdout/stderr can never permanently hold a ShellRunner worker slot.
        drainSignal.markChildExited()
        readGroup.wait()

        let exitCode: Int32
        let statusMasked = rawStatus & 0x7f
        if statusMasked == 0 {
            exitCode = (rawStatus >> 8) & 0xff
        } else {
            exitCode = statusMasked
        }

        let durationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return ShellResult(
            exitCode: exitCode,
            timedOut: didTimeout,
            stdout: stdoutBox.value,
            stderr: stderrBox.value,
            durationMilliseconds: durationMilliseconds
        )
    }

    // MARK: - Native NSWorkspace actions

    public static func runApp(target: String, arguments: [String] = []) -> ShellResult {
        let started = Date()
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appURL = resolveApplicationURL(for: trimmed) {
            return launchApplication(at: appURL, target: trimmed, arguments: arguments, started: started)
        }
        // Fall back to /usr/bin/open -a for LaunchServices display names or bundles outside standard
        // search roots; explicit paths must exist at the specified location rather than falling back.
        if !trimmed.isEmpty,
           !trimmed.hasPrefix("/"),
           !trimmed.hasPrefix("~/"),
           !trimmed.contains("/"),
           !trimmed.hasPrefix("-") {
            var openArgs = ["/usr/bin/open", "-a", trimmed]
            if !arguments.isEmpty {
                openArgs.append("--args")
                openArgs.append(contentsOf: arguments)
            }
            return runExecutable(
                executablePath: "/usr/bin/open",
                arguments: openArgs,
                environment: scrubbedEnvironment(allowAccessibility: false),
                workingDirectory: Paths.realHomeDirectory.path,
                timeoutMilliseconds: 10_000,
                disclaimResponsibility: true,
                started: started
            )
        }
        return ShellResult(
            exitCode: 1,
            timedOut: false,
            stdout: "",
            stderr: "application '\(trimmed)' could not be found",
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private static func launchApplication(
        at appURL: URL,
        target: String,
        arguments: [String],
        started: Date
    ) -> ShellResult {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = arguments
        configuration.environment = [:]

        final class OpenBox: @unchecked Sendable {
            var errorMessage: String?
        }
        let box = OpenBox()
        let semaphore = DispatchSemaphore(value: 0)

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                box.errorMessage = error.localizedDescription
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(10))
        let durationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        if waitResult == .timedOut {
            return ShellResult(
                exitCode: -1,
                timedOut: true,
                stdout: "",
                stderr: "timed out launching '\(target)'",
                durationMilliseconds: durationMilliseconds
            )
        }
        if let errorMessage = box.errorMessage {
            return ShellResult(
                exitCode: 1,
                timedOut: false,
                stdout: "",
                stderr: errorMessage,
                durationMilliseconds: durationMilliseconds
            )
        }
        return ShellResult(
            exitCode: 0,
            timedOut: false,
            stdout: "",
            stderr: "",
            durationMilliseconds: durationMilliseconds
        )
    }

    public static func runURL(_ rawURL: String) -> ShellResult {
        let started = Date()
        guard let url = Action.validatedWebURL(rawURL) else {
            return ShellResult(
                exitCode: 1,
                timedOut: false,
                stdout: "",
                stderr: "refusing to open disallowed URL '\(rawURL)'; only http:// and https:// are permitted",
                durationMilliseconds: 0
            )
        }
        let opened = NSWorkspace.shared.open(url)
        let durationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return ShellResult(
            exitCode: opened ? 0 : 1,
            timedOut: false,
            stdout: "",
            stderr: opened ? "" : "could not open URL '\(rawURL)'",
            durationMilliseconds: durationMilliseconds
        )
    }

    /// Opens `rawPath` natively in Finder via `NSWorkspace` ONLY when `rawPath` resolves to an
    /// existing plain directory (`~`, `~/Downloads`, etc.) — never symlinks, `.app` bundles, or
    /// macOS file packages. Returns `nil` otherwise so callers fall back to a disclaimed child.
    public static func runOpenDirectory(_ rawPath: String) -> ShellResult? {
        let started = Date()
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let expanded = Paths.expandTilde(trimmed)

        let fd = open(expanded, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &pathBuf) != -1 else {
            return nil
        }
        let realPath = String(cString: pathBuf)
        guard !realPath.isEmpty else { return nil }

        let realURL = URL(fileURLWithPath: realPath, isDirectory: true)
        if isBundleDirectoryName(realURL.lastPathComponent)
            || NSWorkspace.shared.isFilePackage(atPath: realPath) {
            return nil
        }
        guard let values = try? realURL.resourceValues(forKeys: [
            .isPackageKey, .isApplicationKey, .isAliasFileKey, .isSymbolicLinkKey
        ]),
              values.isPackage != true,
              values.isApplication != true,
              values.isAliasFile != true,
              values.isSymbolicLink != true else {
            return nil
        }

        let opened = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: realPath)
        let durationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return ShellResult(
            exitCode: opened ? 0 : 1,
            timedOut: false,
            stdout: "",
            stderr: opened ? "" : "could not open directory '\(trimmed)'",
            durationMilliseconds: durationMilliseconds
        )
    }

    private static let nonSearchableBundleExtensions: [String] = [
        ".app", ".framework", ".xpc", ".bundle", ".plugin",
        ".appex", ".kext", ".qlgenerator", ".mdimporter", ".prefpane",
        ".workflow", ".saver", ".pkg", ".mpkg", ".scptd"
    ]

    private static func isBundleDirectoryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return nonSearchableBundleExtensions.contains { lower.hasSuffix($0) }
    }

    private static func isAcceptableDirectory(_ path: String) -> Bool {
        var lst = stat()
        guard lstat(path, &lst) == 0 else { return false }
        let ftype = lst.st_mode & S_IFMT
        if ftype == S_IFDIR {
            return true
        }
        // Allow root-owned Apple system symlinks (e.g. /Applications/Safari.app Cryptex link),
        // while refusing user-owned symlinks.
        if ftype == S_IFLNK && lst.st_uid == 0 {
            var st = stat()
            return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        return false
    }

    private static func isAllowedBundleLocation(_ url: URL) -> Bool {
        let home = Paths.realHomeDirectory.path
        let downloadsPrefix = home + "/Downloads/"
        let trashPrefix = home + "/.Trash/"
        for candidate in [url.path, url.resolvingSymlinksInPath().path] {
            if CodeTrust.isForbiddenInstallPath(candidate)
                || candidate.hasPrefix("/Volumes/")
                || candidate.hasPrefix(downloadsPrefix)
                || candidate.hasPrefix(trashPrefix) {
                return false
            }
        }
        return true
    }

    /// Resolves an application URL from a `.app` path, bundle identifier, or app name across
    /// standard macOS application directories (preferring system-owned `/System/Applications` and
    /// `/Applications` trees ahead of user-writable `~/Applications`).
    public static func resolveApplicationURL(
        for target: String,
        searchRoots: [String]? = nil
    ) -> URL? {
        guard !target.isEmpty, !target.contains("\0") else { return nil }

        if target.hasPrefix("/") || target.hasPrefix("~/") {
            let expanded = Paths.expandTilde(target)
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard url.pathExtension.lowercased() == "app",
                  isAcceptableDirectory(url.path) else {
                return nil
            }
            return url
        }

        guard !target.contains("/") else { return nil }

        let cacheKey = target.lowercased()
        if searchRoots == nil {
            let now = CFAbsoluteTimeGetCurrent()
            appCacheLock.lock()
            let cached = appURLCache[cacheKey]
            appCacheLock.unlock()
            if let cached, now - cached.cachedAt < appCacheTTLSeconds {
                if isAllowedBundleLocation(cached.url), isAcceptableDirectory(cached.url.path) {
                    return cached.url
                }
                appCacheLock.lock()
                appURLCache.removeValue(forKey: cacheKey)
                appCacheLock.unlock()
            }
        }

        let resolved: URL?
        if searchRoots == nil,
           let byBundleID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target),
           isAllowedBundleLocation(byBundleID),
           isAcceptableDirectory(byBundleID.path) {
            resolved = byBundleID
        } else {
            let bundleName = target.lowercased().hasSuffix(".app") ? target : "\(target).app"
            if let customRoots = searchRoots {
                return searchApplicationBundle(named: bundleName, in: customRoots)
            }

            let systemRoots = [
                "/System/Applications",
                "/System/Applications/Utilities",
                "/System/Library/CoreServices",
                "/System/Library/CoreServices/Applications",
                "/Applications"
            ]
            if let systemMatch = searchApplicationBundle(named: bundleName, in: systemRoots) {
                resolved = systemMatch
            } else {
                let userRoots = [
                    Paths.realHomeDirectory.appendingPathComponent("Applications").path
                ]
                resolved = searchApplicationBundle(named: bundleName, in: userRoots)
            }
        }

        if let resolved, searchRoots == nil {
            appCacheLock.lock()
            appURLCache[cacheKey] = (resolved, CFAbsoluteTimeGetCurrent())
            appCacheLock.unlock()
        }
        return resolved
    }

    private static func searchApplicationBundle(named bundleName: String, in roots: [String]) -> URL? {
        let fm = FileManager.default
        var visited: Set<String> = []
        var frontier: [URL] = []
        for root in roots {
            let url = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            if isAcceptableDirectory(url.path), visited.insert(url.path).inserted {
                frontier.append(url)
            }
        }

        for depth in 0...2 {
            guard !frontier.isEmpty else { break }

            var levelEntries: [(dirURL: URL, entries: [String])] = []
            levelEntries.reserveCapacity(frontier.count)
            for dirURL in frontier {
                if let entries = try? fm.contentsOfDirectory(atPath: dirURL.path) {
                    levelEntries.append((dirURL, entries))
                }
            }

            // Pass 1: exact case-sensitive filename match at this depth level.
            for item in levelEntries where item.entries.contains(bundleName) {
                let candidate = item.dirURL.appendingPathComponent(bundleName)
                if isAcceptableDirectory(candidate.path) {
                    return candidate
                }
            }

            // Pass 2: case-insensitive filename match (preserves on-disk casing on APFS).
            for item in levelEntries {
                if let match = item.entries.first(where: { $0.caseInsensitiveCompare(bundleName) == .orderedSame }) {
                    let candidate = item.dirURL.appendingPathComponent(match)
                    if isAcceptableDirectory(candidate.path) {
                        return candidate
                    }
                }
            }

            guard depth < 2 else { break }
            var nextFrontier: [URL] = []
            for item in levelEntries {
                for entry in item.entries where !entry.hasPrefix(".") && !isBundleDirectoryName(entry) {
                    let subURL = item.dirURL.appendingPathComponent(entry, isDirectory: true).standardizedFileURL
                    if isAcceptableDirectory(subURL.path),
                       visited.insert(subURL.path).inserted {
                        nextFrontier.append(subURL)
                    }
                }
            }
            frontier = nextFrontier
        }
        return nil
    }

    // MARK: - Helpers

    private static func validatedLocale() -> String {
        guard let raw = getenv("LANG") else { return "en_US.UTF-8" }
        let candidate = String(cString: raw)
        guard !candidate.isEmpty, candidate.count <= 64 else { return "en_US.UTF-8" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "en_US.UTF-8"
        }
        return candidate
    }

    private final class PipeDrainSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var childExitedAt: CFAbsoluteTime?
        private let graceSeconds: Double

        init(graceSeconds: Double) {
            self.graceSeconds = graceSeconds
        }

        func markChildExited() {
            lock.lock()
            if childExitedAt == nil {
                childExitedAt = CFAbsoluteTimeGetCurrent()
            }
            lock.unlock()
        }

        func remainingDrainMilliseconds() -> Int32? {
            lock.lock()
            let exitedAt = childExitedAt
            lock.unlock()
            guard let exitedAt else { return nil }
            let remaining = graceSeconds - (CFAbsoluteTimeGetCurrent() - exitedAt)
            if remaining <= 0 { return 0 }
            return Int32(max(1, min(50, Int(remaining * 1000))))
        }
    }

    private static func readBoundedPipe(
        fd: Int32,
        maxBytes: Int = 4096,
        drainSignal: PipeDrainSignal? = nil
    ) -> String {
        var collected: [UInt8] = []
        collected.reserveCapacity(min(maxBytes, 1024))
        var truncated = false
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollTimeoutMs: Int32
            if let remaining = drainSignal?.remainingDrainMilliseconds() {
                if remaining <= 0 {
                    break
                }
                pollTimeoutMs = remaining
            } else {
                pollTimeoutMs = 50
            }

            let ready = Darwin.poll(&pfd, 1, pollTimeoutMs)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if let remaining = drainSignal?.remainingDrainMilliseconds(), remaining <= 0 {
                    break
                }
                continue
            }

            var reachedEOF = false
            while true {
                let count = chunk.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.read(fd, baseAddress, rawBuffer.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    reachedEOF = true
                    break
                }
                if count == 0 {
                    reachedEOF = true
                    break
                }
                if collected.count < maxBytes {
                    let remaining = maxBytes - collected.count
                    if count <= remaining {
                        collected.append(contentsOf: chunk[0..<count])
                    } else {
                        collected.append(contentsOf: chunk[0..<remaining])
                        truncated = true
                    }
                } else {
                    truncated = true
                }
            }

            if reachedEOF || (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                break
            }
        }

        let text = String(decoding: collected, as: UTF8.self)
        return truncated ? text + "\n… truncated" : text
    }

    private static func withCStrings(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> CInt
    ) -> CInt {
        var cStrings: [UnsafeMutablePointer<CChar>?] = []
        cStrings.reserveCapacity(strings.count + 1)
        defer {
            for ptr in cStrings where ptr != nil {
                free(ptr)
            }
        }
        for item in strings {
            if item.contains("\0") {
                return EINVAL
            }
            guard let dup = strdup(item) else {
                return ENOMEM
            }
            cStrings.append(dup)
        }
        cStrings.append(nil)
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func singleLine(_ value: String, limit: Int = 300) -> String {
        let flattened = Log.sanitizeMessage(value.replacingOccurrences(of: "\n", with: " ; "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }
}
