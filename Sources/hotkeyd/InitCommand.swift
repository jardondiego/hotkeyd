import AppKit
import Carbon
import Darwin
import Foundation
import HotkeydCore

struct InitPayload: Encodable {
    let status: String
    let dryRun: Bool
    let alreadyConfigured: Bool
    let binaryPath: String
    let configPath: String
    let configState: String
    let configCreated: Bool
    let configRepaired: Bool
    let shortcutsAdded: Int
    let shortcutCount: Int
    let plannedStarters: [InitStarterBinding]
    let daemonInstalled: Bool
    let daemonPID: Int?
    let allowAdhoc: Bool
    let tapActive: Bool
    let secureInputActive: Bool
    let verified: Bool
    let verificationCandidate: VerificationCandidate?
    let nextSteps: [String]
}

func commandInit(_ arguments: [String]) throws {
    let startedAt = Date()
    let parsed = try parseArguments(
        arguments,
        valued: ["starter"],
        switches: [
            "no-daemon",
            "no-open",
            "no-verify",
            "allow-adhoc",
            "dry-run",
            "non-interactive",
            "json",
            "help"
        ]
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["init"])
        return
    }

    let starterPreset: InitStarterPreset?
    if let rawStarter = parsed.values["starter"] {
        guard let preset = InitStarterPreset(rawValue: rawStarter.lowercased()) else {
            throw CLIError(
                message: "invalid --starter value '\(rawStarter)' (expected minimal, empty, or skip)",
                code: 2,
                hint: "run `hotkeyd help init` for usage"
            )
        }
        starterPreset = preset
    } else {
        starterPreset = nil
    }

    let jsonMode = wantsJSON(parsed)
    let dryRun = parsed.switches.contains("dry-run")
    let nonInteractiveFlag = parsed.switches.contains("non-interactive")
    let noDaemon = parsed.switches.contains("no-daemon")
    let noOpen = parsed.switches.contains("no-open")
    let noVerify = parsed.switches.contains("no-verify")
    let allowAdhoc = parsed.switches.contains("allow-adhoc")
    let sandboxed = Paths.isEnvironmentOverrideActive

    let interactiveTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    if !dryRun && !nonInteractiveFlag && !interactiveTTY {
        throw CLIError(
            message: "hotkeyd init requires an interactive terminal (or pass --non-interactive)",
            code: 2,
            hint: "for scripts and agents, run: hotkeyd init --non-interactive --starter minimal --json"
        )
    }

    if sandboxed && !noDaemon && !dryRun {
        throw CLIError(
            message: "HOTKEYD_HOME is set; refusing to manage the live LaunchAgent",
            code: 2,
            hint: "pass --no-daemon to initialize only \(Paths.config.path), or unset HOTKEYD_HOME"
        )
    }

    let headless = nonInteractiveFlag || jsonMode
    let binaryPath = rawExecutablePath()
    let effectiveNoDaemon = noDaemon || sandboxed

    // Fast path: idempotent already-healthy check (skipped for --dry-run and --no-daemon).
    if !dryRun && !effectiveNoDaemon {
        if let healthy = checkAlreadyHealthy(binaryPath: binaryPath, allowAdhoc: allowAdhoc) {
            let payload = InitPayload(
                status: "ready",
                dryRun: false,
                alreadyConfigured: true,
                binaryPath: healthy.binaryPath,
                configPath: Paths.config.path,
                configState: "valid",
                configCreated: false,
                configRepaired: false,
                shortcutsAdded: 0,
                shortcutCount: healthy.shortcutCount,
                plannedStarters: [],
                daemonInstalled: true,
                daemonPID: healthy.pid,
                allowAdhoc: healthy.allowsAdhoc,
                tapActive: true,
                secureInputActive: IsSecureEventInputEnabled(),
                verified: false,
                verificationCandidate: nil,
                nextSteps: []
            )
            if jsonMode {
                try emitJSON("init", payload, ok: true)
            } else {
                print("✓ Already configured and active — \(healthy.shortcutCount) shortcut(s), daemon pid \(healthy.pid), event tap listening.")
                print("  Run `hotkeyd doctor` for full diagnostics, or `hotkeyd edit` to modify shortcuts.")
            }
            return
        }
    }

    if !jsonMode {
        print(dryRun ? "hotkeyd init --dry-run" : "hotkeyd init")
        print("")
        print("Step 1/4  Preflight")
    }

    // Step 1/4 — Preflight: verify binary path & signing (when daemon is in scope).
    var effectiveAllowAdhoc = allowAdhoc
    if !effectiveNoDaemon {
        do {
            if CodeTrust.isForbiddenInstallPath(binaryPath) {
                throw CodeTrust.TrustError.forbiddenBuildOrTempPath(binaryPath)
            }
            try StrictModes.verifySecurePath(binaryPath, expectRegularFile: true)
            let report = try CodeTrust.verify(binaryPath: binaryPath, allowAdhoc: allowAdhoc)
            effectiveAllowAdhoc = allowAdhoc && report.isAdhoc
            if !jsonMode {
                print("  ✓ Binary verified (\(binaryPath))")
                if report.isAdhoc {
                    print("  ! Signing: ad-hoc + Hardened Runtime (--allow-adhoc; SELECTED_TEXT & Accessibility delegation disabled)")
                } else {
                    print("  ✓ Signing valid (Developer certificate, Hardened Runtime)")
                }
            }
        } catch {
            let classified = InitSupport.classifyExecutableTrustError(
                error,
                binaryPath: binaryPath,
                allowAdhoc: allowAdhoc
            )
            if dryRun {
                let payload = InitPayload(
                    status: "preflight_failed",
                    dryRun: true,
                    alreadyConfigured: false,
                    binaryPath: binaryPath,
                    configPath: Paths.config.path,
                    configState: InitSupport.inspectConfigState(at: Paths.config).kindName,
                    configCreated: false,
                    configRepaired: false,
                    shortcutsAdded: 0,
                    shortcutCount: 0,
                    plannedStarters: [],
                    daemonInstalled: false,
                    daemonPID: nil,
                    allowAdhoc: allowAdhoc,
                    tapActive: false,
                    secureInputActive: IsSecureEventInputEnabled(),
                    verified: false,
                    verificationCandidate: nil,
                    nextSteps: [classified.fix]
                )
                if jsonMode {
                    try emitJSON("init", payload, ok: false)
                } else {
                    print("  ✗ \(classified.summary)")
                    print("    fix: \(classified.fix)")
                }
                exit(7)
            }
            throw CLIError(
                message: classified.summary,
                code: 7,
                kind: "config_io",
                hint: classified.fix
            )
        }
    } else if !jsonMode {
        let reason = sandboxed ? "HOTKEYD_HOME sandbox active" : "--no-daemon"
        print("  ✓ Config-only mode (\(reason))")
    }

    // Step 1/4 (cont.) — Inspect and optionally repair ~/.hotkeyd.
    var configState = InitSupport.inspectConfigState(at: Paths.config)
    var configRepaired = false

    switch configState {
    case .loosePermissions(let mode):
        let octal = String(format: "%04o", mode)
        let chmodCmd = "chmod 0600 \(Action.shellSingleQuote(Paths.config.path))"
        let wasGroupOrWorldWritable = (mode & (S_IWGRP | S_IWOTH)) != 0
        if dryRun {
            if !jsonMode {
                print("  ! \(Paths.config.path) has loose permissions (\(octal)); requires 0600")
                if wasGroupOrWorldWritable {
                    print("    WARNING: group/world write bits are set; inspect the file for tampering before tightening.")
                }
                print("    fix: \(chmodCmd)")
            }
        } else if headless {
            throw CLIError(
                message: "\(Paths.config.path) has loose permissions (\(octal)); Hotkeyd requires 0600",
                code: 7,
                kind: "config_io",
                hint: chmodCmd
            )
        } else {
            print("  ! \(Paths.config.path) has loose permissions (\(octal)); Hotkeyd requires 0600.")
            if wasGroupOrWorldWritable {
                print("    WARNING: group/world write bits were set (\(octal)); another local user could have modified this file.")
                print("    Review \(Paths.config.path) carefully before enabling it.")
            }
            if promptYesNo("  Tighten permissions to 0600 now?", defaultYes: !wasGroupOrWorldWritable) {
                try InitSupport.fixLoosePermissions(at: Paths.config)
                configRepaired = true
                configState = InitSupport.inspectConfigState(at: Paths.config)
                print("  ✓ Tightened \(Paths.config.path) to 0600")
            } else {
                throw CLIError(
                    message: "refusing to continue with loose permissions (\(octal)) on \(Paths.config.path)",
                    code: 7,
                    kind: "config_io",
                    hint: chmodCmd
                )
            }
        }

    case .symlink(let target):
        let displayTarget = StrictModes.sanitizeTerminalText(target)
        let resolvedTarget = target.hasPrefix("/")
            ? target
            : Paths.config.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        let copyCmd = "install -m 0600 \(Action.shellSingleQuote(resolvedTarget)) \(Action.shellSingleQuote(Paths.config.path))"
        if dryRun {
            if !jsonMode {
                print("  ! \(Paths.config.path) is a symlink -> \(displayTarget)")
                print("    Hotkeyd requires a regular 0600 file (O_NOFOLLOW) so link targets cannot be swapped.")
                print("    fix: \(copyCmd)")
            }
        } else if headless {
            throw CLIError(
                message: "\(Paths.config.path) is a symlink (-> \(displayTarget)); Hotkeyd requires a regular 0600 file (O_NOFOLLOW)",
                code: 7,
                kind: "config_io",
                hint: copyCmd
            )
        } else {
            print("  ! \(Paths.config.path) is a symlink -> \(displayTarget)")
            print("    Hotkeyd requires a regular 0600 file (O_NOFOLLOW) so untrusted link targets cannot be swapped.")
            if promptYesNo("  Copy target to a regular 0600 file at \(Paths.config.path) now?", defaultYes: true) {
                do {
                    let materialized = try InitSupport.materializeSymlinkConfig(at: Paths.config)
                    configRepaired = true
                    configState = InitSupport.inspectConfigState(at: Paths.config)
                    print("  ✓ Materialized \(Paths.config.path) (0600, \(materialized.shortcuts.count) shortcut(s) kept untouched)")
                } catch {
                    throw CLIError(
                        message: "could not materialize symlinked config: \(error.localizedDescription)",
                        code: 7,
                        kind: "config_io",
                        hint: copyCmd
                    )
                }
            } else {
                throw CLIError(
                    message: "symlinked config at \(Paths.config.path) is not allowed",
                    code: 7,
                    kind: "config_io",
                    hint: copyCmd
                )
            }
        }

    case .invalid(let reason):
        if dryRun && jsonMode {
            let payload = InitPayload(
                status: "config_invalid",
                dryRun: true,
                alreadyConfigured: false,
                binaryPath: binaryPath,
                configPath: Paths.config.path,
                configState: "invalid",
                configCreated: false,
                configRepaired: false,
                shortcutsAdded: 0,
                shortcutCount: 0,
                plannedStarters: [],
                daemonInstalled: false,
                daemonPID: nil,
                allowAdhoc: effectiveAllowAdhoc,
                tapActive: false,
                secureInputActive: IsSecureEventInputEnabled(),
                verified: false,
                verificationCandidate: nil,
                nextSteps: ["fix \(Paths.config.path) or run `hotkeyd edit`"]
            )
            try emitJSON("init", payload, ok: false)
            exit(7)
        }
        throw CLIError(
            message: "invalid configuration at \(Paths.config.path): \(reason)",
            code: 7,
            kind: "config_io",
            hint: "fix \(Paths.config.path) or run `hotkeyd edit` (init never overwrites an existing file)"
        )

    case .valid, .empty, .missing:
        break
    }

    // Re-check invalid state after a repair (e.g., chmod 0600 revealed malformed JSON).
    if case .invalid(let reason) = configState {
        throw CLIError(
            message: "invalid configuration at \(Paths.config.path): \(reason)",
            code: 7,
            kind: "config_io",
            hint: "fix \(Paths.config.path) or run `hotkeyd edit`"
        )
    }

    // Step 2/4 — Starter shortcuts (Config-First, before touching launchd or Accessibility!).
    if !jsonMode {
        print("")
        print("Step 2/4  Starter shortcuts (\(Paths.config.path))")
    }

    var activeConfig: Config?
    var configCreated = false
    var shortcutsAdded = 0
    var plannedStarters: [InitStarterBinding] = []

    switch configState {
    case .valid(let count, let cfg):
        activeConfig = cfg
        if !jsonMode {
            print("  ✓ Keeping existing \(Paths.config.path) (\(count) shortcut(s))")
        }

    case .missing, .empty:
        let isEmptyExisting: Bool
        if case .empty(let cfg) = configState {
            isEmptyExisting = true
            activeConfig = cfg
        } else {
            isEmptyExisting = false
        }

        let detectedStarters = InitSupport.buildMinimalStarters()
        let chosenPreset: InitStarterPreset

        if let explicit = starterPreset {
            chosenPreset = explicit
        } else if dryRun {
            chosenPreset = .minimal
        } else if headless {
            if !isEmptyExisting {
                throw CLIError(
                    message: "--starter is required in non-interactive mode when \(Paths.config.path) does not exist",
                    code: 2,
                    kind: "usage",
                    hint: "pass --starter minimal, --starter empty, or --starter skip"
                )
            }
            chosenPreset = .skip
        } else {
            print("  Detected defaults for this Mac:")
            for item in detectedStarters {
                print("    \(pad(item.keys, 5)) (\(pad(item.label, 24))) ->  \(item.summary)")
            }
            print("")
            let prompt = isEmptyExisting
                ? "  \(Paths.config.path) is empty. Add these \(detectedStarters.count) starter shortcuts? [Y/n]"
                : "  Write these \(detectedStarters.count) starter shortcuts to \(Paths.config.path)? [Y/n/e(mpty)]"
            chosenPreset = promptStarterChoice(prompt: prompt, allowEmptyOption: !isEmptyExisting)
        }

        switch chosenPreset {
        case .minimal:
            plannedStarters = detectedStarters
            let shortcuts = try detectedStarters.map { try $0.toShortcut() }
            let starterConfig = Config(shortcuts: shortcuts)
            try starterConfig.validate()
            activeConfig = starterConfig
            if dryRun {
                if !jsonMode {
                    print("  [dry-run] Would write \(shortcuts.count) starter shortcut(s) to \(Paths.config.path) (0600):")
                    for item in detectedStarters {
                        print("    \(pad(item.keys, 5)) -> \(item.command)  (\(item.source))")
                    }
                }
            } else {
                try Config.withExclusiveLock(for: Paths.config) {
                    try starterConfig.save(to: Paths.config)
                }
                configCreated = !isEmptyExisting
                shortcutsAdded = shortcuts.count
                if !jsonMode {
                    print("  ✓ Saved \(Paths.config.path) (0600, \(shortcuts.count) shortcuts)")
                }
            }

        case .empty:
            let emptyConfig = Config()
            activeConfig = emptyConfig
            if dryRun {
                if !jsonMode {
                    print("  [dry-run] Would write an empty 0600 config to \(Paths.config.path)")
                }
            } else if !isEmptyExisting {
                try Config.withExclusiveLock(for: Paths.config) {
                    try emptyConfig.save(to: Paths.config)
                }
                configCreated = true
                if !jsonMode {
                    print("  ✓ Created empty \(Paths.config.path) (0600)")
                }
            } else if !jsonMode {
                print("  ✓ Keeping empty \(Paths.config.path)")
            }

        case .skip:
            if !jsonMode {
                print("  Skipped starter shortcuts.")
            }
        }

    case .loosePermissions, .symlink:
        // Only reachable in --dry-run (non-dry-run already repaired or exited above).
        if !jsonMode {
            print("  [dry-run] Resolve Step 1 config permission/symlink issue before writing or loading shortcuts.")
        }

    case .invalid:
        break
    }

    let currentShortcutCount = activeConfig?.shortcuts.count ?? 0
    let previewCandidate = activeConfig.flatMap {
        InitSupport.selectSafeVerificationCandidate(
            from: $0,
            capsLockRemapped: CapsLock.state() == .enabled
        )
    }

    // Dry-run stops cleanly here with zero filesystem/launchd mutations.
    if dryRun {
        let needsConfigFix: Bool
        switch configState {
        case .loosePermissions, .symlink, .invalid:
            needsConfigFix = true
        case .missing, .empty, .valid:
            needsConfigFix = false
        }

        var nextSteps: [String] = []
        if case .loosePermissions = configState {
            nextSteps.append("chmod 0600 \(Action.shellSingleQuote(Paths.config.path))")
        } else if case .symlink(let target) = configState {
            let resolvedTarget = target.hasPrefix("/")
                ? target
                : Paths.config.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
            nextSteps.append("install -m 0600 \(Action.shellSingleQuote(resolvedTarget)) \(Action.shellSingleQuote(Paths.config.path))")
        }
        if !effectiveNoDaemon {
            nextSteps.append("run `hotkeyd init` to apply changes, install the LaunchAgent, and verify Accessibility")
        } else if case .valid = configState {
            nextSteps.append("configuration is valid; run `hotkeyd init` without --no-daemon to install or verify the daemon")
        } else {
            nextSteps.append("run `hotkeyd init --no-daemon` to write \(Paths.config.path)")
        }

        let payload = InitPayload(
            status: needsConfigFix ? "dry_run_needs_repair" : "dry_run",
            dryRun: true,
            alreadyConfigured: false,
            binaryPath: binaryPath,
            configPath: Paths.config.path,
            configState: configState.kindName,
            configCreated: false,
            configRepaired: false,
            shortcutsAdded: 0,
            shortcutCount: currentShortcutCount,
            plannedStarters: plannedStarters,
            daemonInstalled: false,
            daemonPID: effectiveNoDaemon ? nil : LaunchAgent.pid(),
            allowAdhoc: effectiveAllowAdhoc,
            tapActive: effectiveNoDaemon ? false : tapState(daemonPID: LaunchAgent.pid(), sandboxed: false).installed,
            secureInputActive: IsSecureEventInputEnabled(),
            verified: false,
            verificationCandidate: previewCandidate,
            nextSteps: nextSteps
        )
        if jsonMode {
            try emitJSON("init", payload, ok: !needsConfigFix)
        } else {
            print("")
            print("Step 3/4  Background daemon & Accessibility (dry-run)")
            if effectiveNoDaemon {
                print("  [dry-run] Skipped (\(sandboxed ? "HOTKEYD_HOME" : "--no-daemon")).")
            } else {
                print("  [dry-run] Would install LaunchAgent at \(LaunchAgent.plistPath)")
                print("  [dry-run] Daemon binary: \(binaryPath)")
            }
            print("")
            print("Step 4/4  Verify live trigger (dry-run)")
            if let candidate = previewCandidate, !noVerify, !effectiveNoDaemon {
                print("  [dry-run] Would prompt: \(candidate.humanPrompt) to \(candidate.actionSummary)")
            } else {
                print("  [dry-run] Live verification skipped.")
            }
            print("")
            print("Dry-run complete — no files or launchd jobs were modified.")
        }
        if needsConfigFix {
            exit(7)
        }
        return
    }

    // Config-only completion (--no-daemon or HOTKEYD_HOME).
    if effectiveNoDaemon {
        let payload = InitPayload(
            status: "config_ready",
            dryRun: false,
            alreadyConfigured: false,
            binaryPath: binaryPath,
            configPath: Paths.config.path,
            configState: InitSupport.inspectConfigState(at: Paths.config).kindName,
            configCreated: configCreated,
            configRepaired: configRepaired,
            shortcutsAdded: shortcutsAdded,
            shortcutCount: currentShortcutCount,
            plannedStarters: plannedStarters,
            daemonInstalled: false,
            daemonPID: nil,
            allowAdhoc: effectiveAllowAdhoc,
            tapActive: false,
            secureInputActive: IsSecureEventInputEnabled(),
            verified: false,
            verificationCandidate: nil,
            nextSteps: sandboxed
                ? ["unset HOTKEYD_HOME and run `hotkeyd init` when ready to install the live daemon"]
                : ["run `hotkeyd init` or `hotkeyd daemon install` when ready to start the daemon"]
        )
        if jsonMode {
            try emitJSON("init", payload, ok: true)
        } else {
            print("")
            print("Configuration ready at \(Paths.config.path) (\(currentShortcutCount) shortcut(s)).")
            print("  Run `hotkeyd list` to inspect shortcuts, or `hotkeyd init` without --no-daemon to start the daemon.")
        }
        return
    }

    // Step 3/4 — Background daemon & live Accessibility handoff.
    let previousInstalledBinary = LaunchAgent.installedBinaryPath()
    if !jsonMode {
        print("")
        print("Step 3/4  Background daemon & Accessibility")
        print("  Runs 100% locally, never logs keystrokes. Undo anytime: hotkeyd daemon uninstall")
    }

    do {
        try LaunchAgent.install(
            binaryPath: binaryPath,
            allowAdhoc: effectiveAllowAdhoc,
            suppressAXPrompt: true
        )
    } catch {
        throw CLIError(
            message: error.localizedDescription,
            code: 6,
            kind: "daemon",
            hint: "check `hotkeyd doctor` and `hotkeyd logs --daemon`"
        )
    }

    // Give the freshly launched daemon a short window to publish RuntimeState (and immediately
    // report green if Accessibility is already granted!).
    let initialWait = waitForInitialRuntimeState(timeoutSeconds: 2.0)
    var livePID = initialWait.pid ?? LaunchAgent.pid()
    var liveState = initialWait.state
    var tapActive = liveState?.tapActive ?? false

    if !jsonMode {
        if let pid = livePID {
            print("  ✓ LaunchAgent installed (pid \(pid)) — macOS may show \"Background Items Added\"")
        } else {
            print("  ✓ LaunchAgent installed — macOS may show \"Background Items Added\"")
        }
    }

    if !tapActive {
        if headless {
            let nextSteps = [
                "Open System Settings > Privacy & Security > Accessibility",
                "Enable or add (+ then Cmd+Shift+G) \(binaryPath)",
                "Verify with `hotkeyd doctor --json` or re-run `hotkeyd init --non-interactive --json`"
            ]
            let payload = InitPayload(
                status: "pending_accessibility",
                dryRun: false,
                alreadyConfigured: false,
                binaryPath: binaryPath,
                configPath: Paths.config.path,
                configState: InitSupport.inspectConfigState(at: Paths.config).kindName,
                configCreated: configCreated,
                configRepaired: configRepaired,
                shortcutsAdded: shortcutsAdded,
                shortcutCount: currentShortcutCount,
                plannedStarters: plannedStarters,
                daemonInstalled: true,
                daemonPID: livePID,
                allowAdhoc: effectiveAllowAdhoc,
                tapActive: false,
                secureInputActive: IsSecureEventInputEnabled(),
                verified: false,
                verificationCandidate: previewCandidate,
                nextSteps: nextSteps
            )
            if jsonMode {
                try emitJSON("init", payload, ok: false)
            } else {
                print("  ! Accessibility permission is still required for \(binaryPath)")
                print("    Enable \"hotkeyd\" in System Settings > Privacy & Security > Accessibility, then run `hotkeyd doctor`.")
            }
            exit(5)
        }

        let waitResult = waitForAccessibilityInteractive(
            binaryPath: binaryPath,
            previousBinaryPath: previousInstalledBinary,
            openSettingsInitially: !noOpen,
            initialPID: livePID,
            timeoutSeconds: 120
        )
        switch waitResult {
        case .granted(let pid, let state):
            livePID = pid
            liveState = state
            tapActive = true
            print("  ✓ Accessibility granted — event tap active (\(state.activeBindings) shortcut(s) armed)")

        case .daemonCrashLoop(let detail):
            throw CLIError(
                message: "daemon failed to stay running: \(detail)",
                code: 6,
                kind: "daemon",
                hint: "inspect `hotkeyd logs --daemon` (if another `hotkeyd daemon run` is running, stop it first)"
            )

        case .skipped, .timedOut:
            let reason = (waitResult == .skipped)
                ? "Accessibility step skipped."
                : "Timed out waiting for Accessibility permission (120s)."
            print("")
            print("! \(reason) Setup saved, waiting on Accessibility permission.")
            print("  Enable or add \(binaryPath) in System Settings > Privacy & Security > Accessibility.")
            print("  Then run `hotkeyd init` to verify, or `hotkeyd doctor` anytime.")
            exit(5)
        }
    } else if !jsonMode {
        let armed = liveState?.activeBindings ?? currentShortcutCount
        print("  ✓ Accessibility granted — event tap active (\(armed) shortcut(s) armed)")
    }

    // Ensure daemon reflects our active config bindings before Step 4.
    if currentShortcutCount > 0, (liveState?.activeBindings ?? 0) == 0 {
        notifyDaemonToReload()
        let reloadDeadline = Date().addingTimeInterval(1.5)
        while Date() < reloadDeadline {
            if let pid = LaunchAgent.pid(),
               let st = RuntimeState.load(from: Paths.runtimeState),
               Int(st.pid) == pid,
               st.activeBindings > 0 {
                liveState = st
                break
            }
            usleep(100_000)
        }
    }

    // Step 4/4 — Safe two-stage live verification.
    let candidate = activeConfig.flatMap {
        InitSupport.selectSafeVerificationCandidate(
            from: $0,
            capsLockRemapped: (liveState?.capsRemapped ?? false) || (CapsLock.state() == .enabled)
        )
    }

    var verified = false
    if !headless && !noVerify {
        print("")
        print("Step 4/4  Verify live trigger")
        if let candidate {
            verified = runLiveVerification(candidate: candidate, timeoutSeconds: 20)
        } else {
            print("  Skipped — no non-destructive app shortcut selected for automated smoke test.")
        }
    }

    let payload = InitPayload(
        status: "ready",
        dryRun: false,
        alreadyConfigured: false,
        binaryPath: binaryPath,
        configPath: Paths.config.path,
        configState: InitSupport.inspectConfigState(at: Paths.config).kindName,
        configCreated: configCreated,
        configRepaired: configRepaired,
        shortcutsAdded: shortcutsAdded,
        shortcutCount: currentShortcutCount,
        plannedStarters: plannedStarters,
        daemonInstalled: true,
        daemonPID: livePID ?? LaunchAgent.pid(),
        allowAdhoc: effectiveAllowAdhoc,
        tapActive: tapActive,
        secureInputActive: IsSecureEventInputEnabled(),
        verified: verified,
        verificationCandidate: candidate,
        nextSteps: [
            "hotkeyd list",
            "hotkeyd edit",
            "hotkeyd doctor"
        ]
    )

    if jsonMode {
        try emitJSON("init", payload, ok: true)
        return
    }

    let elapsed = max(1, Int(Date().timeIntervalSince(startedAt).rounded()))
    print("")
    print("Hotkeyd is ready! (\(elapsed)s)")
    print("  hotkeyd list        View active shortcuts")
    print("  hotkeyd edit        Customize \(Paths.config.path) (or `hotkeyd add caps ...` for Caps Lock)")
    print("  hotkeyd doctor      Verify system health anytime")
}

// MARK: - Init helpers

private struct HealthyState {
    let binaryPath: String
    let shortcutCount: Int
    let pid: Int
    let allowsAdhoc: Bool
}

private func checkAlreadyHealthy(binaryPath: String, allowAdhoc: Bool) -> HealthyState? {
    guard case .valid(let shortcutCount, _) = InitSupport.inspectConfigState(at: Paths.config),
          shortcutCount > 0,
          LaunchAgent.isLoaded(),
          let pid = LaunchAgent.pid(),
          let installedBinary = LaunchAgent.installedBinaryPath(),
          installedBinary == binaryPath else {
        return nil
    }
    // Never silently accept an ad-hoc daemon unless `--allow-adhoc` was explicitly requested.
    if LaunchAgent.installedAllowsAdhoc() && !allowAdhoc {
        return nil
    }
    let allowsAdhoc = allowAdhoc
    guard (try? StrictModes.verifySecurePath(installedBinary, expectRegularFile: true)) != nil,
          (try? CodeTrust.verify(binaryPath: installedBinary, allowAdhoc: allowsAdhoc)) != nil,
          (try? CodeTrust.verifyRunningProcess(
              pid: pid_t(pid),
              expectedBinaryPath: installedBinary,
              allowAdhoc: allowsAdhoc
          )) != nil else {
        return nil
    }
    let tap = tapState(daemonPID: pid, sandboxed: false)
    guard tap.installed else { return nil }
    return HealthyState(
        binaryPath: installedBinary,
        shortcutCount: shortcutCount,
        pid: pid,
        allowsAdhoc: allowsAdhoc
    )
}

private func waitForInitialRuntimeState(timeoutSeconds: TimeInterval) -> (pid: Int?, state: RuntimeState?) {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var lastPID: Int?
    while Date() < deadline {
        if let pid = LaunchAgent.pid() {
            lastPID = pid
            if let state = RuntimeState.load(from: Paths.runtimeState),
               Int(state.pid) == pid {
                return (pid, state)
            }
        }
        usleep(100_000)
    }
    return (lastPID ?? LaunchAgent.pid(), nil)
}

private enum AccessibilityWaitResult: Equatable {
    case granted(pid: Int, state: RuntimeState)
    case skipped
    case timedOut
    case daemonCrashLoop(String)
}

private func waitForAccessibilityInteractive(
    binaryPath: String,
    previousBinaryPath: String?,
    openSettingsInitially: Bool,
    initialPID: Int?,
    timeoutSeconds: TimeInterval
) -> AccessibilityWaitResult {
    let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    print("")
    print("  Waiting for Accessibility permission…")
    if openSettingsInitially {
        print("  Opening System Settings > Privacy & Security > Accessibility")
        _ = tool("/usr/bin/open", [settingsURL])
    } else {
        print("  Open System Settings > Privacy & Security > Accessibility")
    }
    print("  Enable or add (+ then ⌘⇧G) this exact binary:")
    print("    \(binaryPath)")

    var staleHintShown = false
    if let previousBinaryPath, previousBinaryPath != binaryPath {
        staleHintShown = true
        print("  Note: binary path changed from \(previousBinaryPath) — remove the old row (-) and re-add (+) if already toggled ON.")
    }
    print("  Helpers (type letter + Enter): [r] reveal in Finder  [c] copy path  [o] reopen Settings  [s] skip")
    fflush(stdout)

    let started = Date()
    let deadline = started.addingTimeInterval(timeoutSeconds)
    var lastSeenPID = initialPID
    var pidChanges = 0
    var firstUnhealthyAt: Date?
    var stdinReader = NonBlockingStdinReader()

    while Date() < deadline {
        // 1. Check live daemon state & crash loops.
        let currentPID = LaunchAgent.pid()
        if let currentPID {
            if let previous = lastSeenPID, previous != currentPID {
                pidChanges += 1
            }
            lastSeenPID = currentPID

            if let state = RuntimeState.load(from: Paths.runtimeState),
               Int(state.pid) == currentPID {
                firstUnhealthyAt = nil
                if state.tapActive {
                    return .granted(pid: currentPID, state: state)
                }
            } else {
                if firstUnhealthyAt == nil { firstUnhealthyAt = Date() }
            }
        } else {
            if firstUnhealthyAt == nil { firstUnhealthyAt = Date() }
        }

        if pidChanges >= 2 || (firstUnhealthyAt.map { Date().timeIntervalSince($0) >= 4.0 } ?? false) {
            let reason = extractLatestDaemonError()
                ?? "daemon exited unexpectedly or did not publish runtime state"
            return .daemonCrashLoop(reason)
        }

        // 2. Progressive stale-TCC hint at 15 seconds.
        if !staleHintShown && Date().timeIntervalSince(started) >= 15 {
            staleHintShown = true
            print("  Still waiting… Already toggled ON? macOS caches older builds — select hotkeyd, click minus (-), then re-add (+) with the path above (or toggle OFF and back ON).")
            fflush(stdout)
        }

        // 3. Zero-termios cooked-mode helper read via bounded non-blocking poll(2) + read(2).
        switch stdinReader.pollLine(timeoutMilliseconds: 250) {
        case .none:
            break
        case .eof:
            return .skipped
        case .line(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch trimmed {
            case "r", "reveal":
                _ = tool("/usr/bin/open", ["-R", binaryPath])
                print("  Revealed binary in Finder (you can drag it straight into Accessibility).")
            case "c", "copy":
                let pb = NSPasteboard.general
                pb.clearContents()
                if pb.setString(binaryPath, forType: .string) {
                    print("  ✓ Copied path to clipboard (press ⌘⇧G in the Accessibility file picker, then ⌘V).")
                } else {
                    print("  ! Could not write to clipboard; copy the path printed above.")
                }
            case "o", "open":
                _ = tool("/usr/bin/open", [settingsURL])
                print("  Reopened System Settings > Privacy & Security > Accessibility.")
            case "s", "skip", "q", "quit":
                return .skipped
            case "":
                break
            default:
                print("  Unknown helper '\(StrictModes.sanitizeTerminalText(trimmed))' — use [r] reveal, [c] copy, [o] reopen Settings, or [s] skip.")
            }
            fflush(stdout)
        }
    }

    return .timedOut
}

private func extractLatestDaemonError() -> String? {
    let lines = tail(Paths.daemonLog, lines: 30, maxBytes: 32_768)
    for line in lines.reversed() {
        if line.contains("daemon startup aborted:")
            || line.contains("code trust check failed:")
            || line.contains("another hotkeyd daemon instance") {
            if let marker = line.range(of: " daemon ") {
                return String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
    }
    return nil
}

private func runLiveVerification(
    candidate: VerificationCandidate,
    timeoutSeconds: TimeInterval
) -> Bool {
    var secureInputWasActive = IsSecureEventInputEnabled()
    if secureInputWasActive {
        print("  ! Secure Event Input is currently active (e.g. Terminal/iTerm \"Secure Keyboard Entry\" or a password field).")
        print("    macOS pauses global hotkeys until Secure Input turns off.")
    }

    var daemonCursor = LogFileCursor.snapshot(at: Paths.daemonLog)
    var actionCursor = LogFileCursor.snapshot(at: Paths.actionLog)

    print("  \(candidate.humanPrompt) now to \(candidate.actionSummary) (press Enter to skip)…")
    fflush(stdout)

    let started = Date()
    let deadline = started.addingTimeInterval(timeoutSeconds)
    var cadenceHintShown = false
    var firedAt: Date?
    var stdinReader = NonBlockingStdinReader()

    while Date() < deadline {
        if let firedAt, Date().timeIntervalSince(firedAt) >= 6.0 {
            print("  ✓ Triggered \(candidate.keys) -> \(candidate.appName) (app launch still in progress)")
            return true
        }

        // Direct live Secure Event Input monitoring.
        let secureNow = IsSecureEventInputEnabled()
        if secureNow && !secureInputWasActive {
            secureInputWasActive = true
            print("  ! Secure Event Input became active — global hotkeys are temporarily paused.")
            fflush(stdout)
        } else if !secureNow && secureInputWasActive {
            secureInputWasActive = false
            print("  ✓ Secure Event Input ended — ready for your keypress!")
            fflush(stdout)
        }

        // Stage 1: instant daemon.log fire detection (~1ms).
        if firedAt == nil {
            for line in daemonCursor.readNewLines() {
                if case .fired = InitSupport.parseDaemonLogLine(line, candidate: candidate) {
                    firedAt = Date()
                    print("  ✓ Trigger detected (\(candidate.keys))…")
                    fflush(stdout)
                    break
                }
            }
        }

        // Stage 2: actions.log execution completion & exit code verification.
        for line in actionCursor.readNewLines() {
            if let event = InitSupport.parseActionLogLine(line, candidate: candidate) {
                switch event {
                case .completed(let exitCode, let durationMs):
                    if exitCode == 0 {
                        print("  ✓ Fired \(candidate.keys) -> \(candidate.appName) (\(durationMs) ms)")
                    } else {
                        print("  ! Triggered \(candidate.keys), but action exited with code \(exitCode) (\(durationMs) ms) — check `hotkeyd logs --actions`.")
                    }
                    return true
                case .timedOut(let durationMs):
                    print("  ! Triggered \(candidate.keys), but action timed out (\(durationMs) ms).")
                    return true
                case .dropped:
                    print("  ! Triggered \(candidate.keys), but the action queue was full.")
                    return true
                case .fired:
                    break
                }
            }
        }

        // Gentle cadence hint for unfamiliar double-tap gesture after 8 seconds.
        if firedAt == nil && candidate.isDoubleTap && !cadenceHintShown && Date().timeIntervalSince(started) >= 8 {
            cadenceHintShown = true
            print("  Tip: tap and release twice quickly (under 0.4s), or press Enter to skip.")
            fflush(stdout)
        }

        // Non-blocking Enter / skip check (zero termios, never blocks on partial input).
        switch stdinReader.pollLine(timeoutMilliseconds: 150) {
        case .none:
            break
        case .eof:
            print("  Skipped live verification.")
            return false
        case .line(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == "s" || trimmed == "skip" || trimmed == "q" {
                print("  Skipped live verification.")
                return false
            }
        }
    }

    if firedAt != nil {
        print("  ✓ Triggered \(candidate.keys) -> \(candidate.appName)")
        return true
    }

    print("  No trigger detected within \(Int(timeoutSeconds))s — run `hotkeyd doctor` or `hotkeyd logs --follow` if shortcuts do not fire.")
    return false
}

// MARK: - Safe O_NOFOLLOW incremental log tailer

private struct LogFileCursor {
    let url: URL
    var inode: UInt64?
    var offset: UInt64

    static func snapshot(at url: URL) -> LogFileCursor {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            return LogFileCursor(url: url, inode: nil, offset: 0)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return LogFileCursor(url: url, inode: nil, offset: 0)
        }
        return LogFileCursor(url: url, inode: st.st_ino, offset: UInt64(max(0, st.st_size)))
    }

    mutating func readNewLines() -> [String] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return []
        }
        let fileSize = UInt64(max(0, st.st_size))
        if inode != st.st_ino || fileSize < offset {
            inode = st.st_ino
            offset = 0
        }
        guard fileSize > offset else { return [] }
        let bytesToRead = Int(min(fileSize - offset, 65_536))
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: bytesToRead)
        var total = 0
        while total < bytesToRead {
            let n = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: total), bytesToRead - total)
            }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            total += n
        }
        guard total > 0 else { return [] }

        // Only advance through the last newline so partial writes are never split.
        let slice = Data(buffer.prefix(total))
        guard let lastNewline = slice.lastIndex(of: UInt8(ascii: "\n")) else {
            return []
        }
        let completeCount = lastNewline + 1
        offset += UInt64(completeCount)
        let text = String(decoding: slice.prefix(completeCount), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - Zero-termios stdin helpers

private func promptYesNo(_ prompt: String, defaultYes: Bool) -> Bool {
    let suffix = defaultYes ? " [Y/n] " : " [y/N] "
    print(prompt + suffix, terminator: "")
    fflush(stdout)
    guard let raw = readLine(strippingNewline: true) else {
        return false
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty { return defaultYes }
    return trimmed == "y" || trimmed == "yes"
}

private func promptStarterChoice(prompt: String, allowEmptyOption: Bool) -> InitStarterPreset {
    print(prompt + " ", terminator: "")
    fflush(stdout)
    guard let raw = readLine(strippingNewline: true) else {
        return .skip
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty || trimmed == "y" || trimmed == "yes" || trimmed == "m" || trimmed == "minimal" {
        return .minimal
    }
    if allowEmptyOption && (trimmed == "e" || trimmed == "empty") {
        return .empty
    }
    return .skip
}

private enum StdinPollResult {
    case none
    case line(String)
    case eof
}

/// Bounded, non-blocking line reader over `STDIN_FILENO` that never mutates `termios` and never
/// blocks indefinitely on partial non-newline TTY input (e.g., `Ctrl-D` flushing bytes without `\n`).
private struct NonBlockingStdinReader {
    private static let maxBufferBytes = 256
    private var buffer: [UInt8] = []
    private var discardingOverflowLine = false

    mutating func pollLine(timeoutMilliseconds: Int32) -> StdinPollResult {
        if let ready = popBufferedLine() {
            return .line(ready)
        }

        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&pfd, 1, timeoutMilliseconds)
        guard ready > 0 else { return .none }
        if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0
            && (pfd.revents & Int16(POLLIN)) == 0 {
            return flushOnEOF()
        }
        guard (pfd.revents & Int16(POLLIN)) != 0 else { return .none }

        let oldFlags = fcntl(STDIN_FILENO, F_GETFL)
        if oldFlags >= 0 && (oldFlags & O_NONBLOCK) == 0 {
            _ = fcntl(STDIN_FILENO, F_SETFL, oldFlags | O_NONBLOCK)
        }
        defer {
            if oldFlags >= 0 && (oldFlags & O_NONBLOCK) == 0 {
                _ = fcntl(STDIN_FILENO, F_SETFL, oldFlags)
            }
        }

        var chunk = [UInt8](repeating: 0, count: 128)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(STDIN_FILENO, base, raw.count)
            }
            if n > 0 {
                for byte in chunk.prefix(n) {
                    if discardingOverflowLine {
                        if byte == UInt8(ascii: "\n") {
                            discardingOverflowLine = false
                            buffer.append(byte)
                        }
                        continue
                    }
                    if buffer.count < Self.maxBufferBytes {
                        buffer.append(byte)
                    } else if byte == UInt8(ascii: "\n") {
                        buffer.append(byte)
                    } else {
                        discardingOverflowLine = true
                    }
                }
                if let line = popBufferedLine() {
                    return .line(line)
                }
                continue
            }
            if n == 0 {
                return flushOnEOF()
            }
            if errno == EINTR { continue }
            // EAGAIN / EWOULDBLOCK: partial input without newline — return without blocking!
            return .none
        }
    }

    private mutating func popBufferedLine() -> String? {
        guard let nlIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let lineBytes = Array(buffer[..<nlIndex])
        buffer.removeFirst(nlIndex + 1)
        let text = String(decoding: lineBytes, as: UTF8.self)
        return text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    private mutating func flushOnEOF() -> StdinPollResult {
        if !buffer.isEmpty {
            let remaining = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return .line(remaining)
        }
        return .eof
    }
}
