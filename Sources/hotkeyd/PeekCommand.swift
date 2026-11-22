import Foundation
import HotkeydCore

struct PeekStatusPayload: Encodable {
    let enabled: Bool
    let triggers: [String]
    let effectiveTriggers: [String]
    let capsLockTriggerDormant: Bool
    let delayMs: Int
    let toggle: String?
    let searchToggle: String?
    let showDisabled: Bool
    let dimUnmatched: Bool
    let isDefault: Bool
    let daemonRunning: Bool
    let paused: Bool
    let sandboxed: Bool
}

struct PeekTogglePayload: Encodable {
    let toggled: Bool
    let mode: String
    let daemonPID: Int
}

struct PeekTerminalPayload: Encodable {
    let snapshot: PeekSnapshot
    let config: PeekConfigSummary
}

struct PeekSearchTerminalPayload: Encodable {
    let query: String
    let totalCount: Int
    let matchedCount: Int
    let items: [PeekSearchItem]
    let config: PeekConfigSummary
}

struct PeekConfigSummary: Encodable {
    let enabled: Bool
    let triggers: [String]
    let delayMs: Int
    let toggle: String?
    let searchToggle: String?
    let showDisabled: Bool
    let dimUnmatched: Bool
    let isDefault: Bool

    init(_ config: PeekConfig) {
        self.enabled = config.enabled
        self.triggers = config.triggers.map(\.token)
        self.delayMs = config.delayMilliseconds
        self.toggle = config.toggle?.canonical
        self.searchToggle = config.searchToggle?.canonical
        self.showDisabled = config.showDisabled
        self.dimUnmatched = config.dimUnmatched
        self.isDefault = config.isDefault
    }
}

struct PeekMutationPayload: Encodable {
    let dryRun: Bool
    let action: String
    let peek: PeekConfigSummary
    let daemonSignaled: Bool
}

func commandPeek(_ arguments: [String]) throws {
    let subcommand: String
    let rest: [String]

    if let first = arguments.first {
        if first == "--help" || first == "-h" || first == "help" {
            let after = Array(arguments.dropFirst())
            if let target = after.first, !target.hasPrefix("-"),
               let spec = CommandRegistry.findCommand(matching: ["peek", target]) {
                print(CommandRegistry.formatHelp(for: spec))
            } else if let groupHelp = CommandRegistry.formatGroupHelp(group: "peek") {
                print(groupHelp)
            }
            return
        }
        if first.hasPrefix("-") {
            // Bare `hotkeyd peek --terminal`, `hotkeyd peek --json`, etc. route to `toggle`.
            subcommand = "toggle"
            rest = arguments
        } else {
            subcommand = first
            rest = Array(arguments.dropFirst())
        }
    } else {
        subcommand = "toggle"
        rest = []
    }

    switch subcommand {
    case "toggle":
        try commandPeekToggle(rest)
    case "status":
        try commandPeekStatus(rest)
    case "enable":
        try commandPeekSetEnabled(rest, enabled: true)
    case "disable":
        try commandPeekSetEnabled(rest, enabled: false)
    case "set":
        try commandPeekSet(rest)
    default:
        throw CLIError(
            message: "unknown peek command '\(subcommand)'",
            code: 2,
            hint: "expected one of: toggle, status, enable, disable, set (or run `hotkeyd peek --terminal`)"
        )
    }
}

private func commandPeekToggle(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: ["query"],
        switches: ["search", "terminal", "show-disabled", "json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["peek", "toggle"])
        return
    }

    let searchMode = parsed.switches.contains("search")
    let terminalMode = parsed.switches.contains("terminal")
    let queryProvided = parsed.values["query"] != nil
    let query = parsed.values["query"] ?? ""

    if queryProvided && (!searchMode || !terminalMode) {
        throw CLIError(
            message: "`--query` requires `--search --terminal`",
            code: 2,
            hint: "example: hotkeyd peek --search --terminal --query qr"
        )
    }

    if parsed.switches.contains("show-disabled") && !terminalMode {
        throw CLIError(
            message: "`--show-disabled` requires `--terminal` (use `hotkeyd peek set --show-disabled` to change the live overlay)",
            code: 2
        )
    }

    if terminalMode {
        let config = try loadConfigForPeekRead()
        let showDisabledOverride: Bool? = parsed.switches.contains("show-disabled") ? true : nil
        if searchMode {
            let searchSnapshot = PeekSearchBuilder.buildSnapshot(
                from: config,
                logsDirectory: Paths.logs,
                showDisabledOverride: showDisabledOverride
            )
            let filtered = PeekSearchMatcher.filter(searchSnapshot.items, query: query)
            if wantsJSON(parsed) {
                try emitJSON("peek.search", PeekSearchTerminalPayload(
                    query: query,
                    totalCount: searchSnapshot.totalCount,
                    matchedCount: filtered.count,
                    items: filtered,
                    config: PeekConfigSummary(config.peek)
                ))
                return
            }
            print(PeekSearchTerminalFormatter.format(searchSnapshot, query: query))
            return
        }

        let snapshot = PeekModel.buildSnapshot(
            from: config,
            mode: .pinned,
            heldModifiers: [],
            showDisabledOverride: showDisabledOverride
        )
        if wantsJSON(parsed) {
            try emitJSON("peek.toggle", PeekTerminalPayload(
                snapshot: snapshot,
                config: PeekConfigSummary(config.peek)
            ))
            return
        }
        print(PeekTerminalFormatter.format(snapshot, config: config.peek))
        return
    }

    if Paths.isEnvironmentOverrideActive {
        throw CLIError(
            message: "refusing to signal the live LaunchAgent overlay while HOTKEYD_HOME is set",
            code: 6,
            hint: searchMode
                ? "pass `--terminal` to test fuzzy search offline (`hotkeyd peek --search --terminal`)"
                : "pass `--terminal` to preview shortcuts offline (`hotkeyd peek --terminal`)"
        )
    }

    let liveConfig = try loadConfigForPeekRead()
    if !liveConfig.peek.enabled {
        throw CLIError(
            message: "peek overlay and Spotlight search HUD are disabled",
            code: 4,
            hint: "opt in with `hotkeyd peek enable` (for CLI/hotkey-only use without hold triggers, also run `hotkeyd peek set --triggers none`), or use `hotkeyd peek --terminal` offline"
        )
    }

    if PauseState.loadActive(from: Paths.pauseState, pruneExpired: false) != nil {
        throw CLIError(
            message: "shortcuts and peek overlay are paused right now",
            code: 6,
            hint: "run `hotkeyd resume` first, or use `hotkeyd peek --terminal` to inspect shortcuts offline"
        )
    }

    let pid: Int
    do {
        pid = searchMode ? try LaunchAgent.togglePeekSearch() : try LaunchAgent.togglePeek()
    } catch {
        throw CLIError(
            message: error.localizedDescription,
            code: 6,
            hint: "run `hotkeyd peek --terminal` to view shortcuts in the terminal without the daemon"
        )
    }

    if wantsJSON(parsed) {
        try emitJSON(
            searchMode ? "peek.search" : "peek.toggle",
            PeekTogglePayload(toggled: true, mode: searchMode ? "search" : "pinned", daemonPID: pid)
        )
        return
    }
    print(searchMode
        ? "✓ Toggled peek search HUD (daemon pid \(pid))."
        : "✓ Toggled peek overlay (daemon pid \(pid)).")
}

private func commandPeekStatus(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"], positionals: 0)
    if parsed.switches.contains("help") {
        printCommandHelp(["peek", "status"])
        return
    }

    let config = try loadConfigForPeekRead()
    let hasCapsLockBinding = config.requiresCapsLockRemap
    let sandboxed = Paths.isEnvironmentOverrideActive
    let daemonRunning = !sandboxed && LaunchAgent.pid() != nil
    let paused = PauseState.loadActive(from: Paths.pauseState, pruneExpired: false) != nil
    let peek = config.peek
    let effective = peek.activeTriggers(capsLockRemapped: hasCapsLockBinding)
    let capsDormant = peek.isCapsLockTriggerDormant(hasCapsLockBinding: hasCapsLockBinding)

    let payload = PeekStatusPayload(
        enabled: peek.enabled,
        triggers: peek.triggers.map(\.token),
        effectiveTriggers: effective.map(\.token),
        capsLockTriggerDormant: capsDormant,
        delayMs: peek.delayMilliseconds,
        toggle: peek.toggle?.canonical,
        searchToggle: peek.searchToggle?.canonical,
        showDisabled: peek.showDisabled,
        dimUnmatched: peek.dimUnmatched,
        isDefault: peek.isDefault,
        daemonRunning: daemonRunning,
        paused: paused,
        sandboxed: sandboxed
    )

    if wantsJSON(parsed) {
        try emitJSON("peek.status", payload)
        return
    }

    print("peek        \(peek.enabled ? "enabled" : "disabled")" + (peek.isDefault ? " (defaults)" : ""))
    let triggersDisplay = peek.triggers.isEmpty
        ? "none"
        : peek.triggers.map { "\($0.token) (\(KeycapFormatter.modifierLabel($0)))" }.joined(separator: ", ")
    print("triggers    \(triggersDisplay)")
    if capsDormant {
        print("            note: capsLock trigger is dormant until at least one capsLock shortcut is enabled")
    }
    print("delay       \(peek.delayMilliseconds) ms")
    print("toggle      \(peek.toggle?.canonical ?? "none")")
    print("search      \(peek.searchToggle?.canonical ?? "none")")
    print("spotlight   \(peek.dimUnmatched ? "dim unmatched (28%)" : "soft highlight (72%)")")
    print("disabled    \(peek.showDisabled ? "shown" : "hidden")")
    if paused {
        print("state       paused (overlay suppressed until `hotkeyd resume`)")
    }
}

private func commandPeekSetEnabled(_ arguments: [String], enabled: Bool) throws {
    let verb = enabled ? "enable" : "disable"
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["dry-run", "json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["peek", verb])
        return
    }
    let dryRun = parsed.switches.contains("dry-run")

    let updatedPeek: PeekConfig = try mutatePeekConfig(dryRun: dryRun) { config in
        config.peek.enabled = enabled
    }
    let signaled = !dryRun && signalDaemonAfterPeekMutation()

    if wantsJSON(parsed) {
        try emitJSON("peek.\(verb)", PeekMutationPayload(
            dryRun: dryRun,
            action: verb,
            peek: PeekConfigSummary(updatedPeek),
            daemonSignaled: signaled
        ))
        return
    }

    if dryRun {
        print("dry-run: would \(verb) peek overlay")
    } else {
        print("✓ Peek overlay \(enabled ? "enabled" : "disabled").")
    }
}

private func commandPeekSet(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: ["triggers", "delay", "toggle", "search-toggle"],
        switches: ["clear-toggle", "clear-search-toggle", "show-disabled", "hide-disabled", "dim", "no-dim", "reset", "dry-run", "json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["peek", "set"])
        return
    }

    let hasToggle = parsed.values["toggle"] != nil
    let clearToggle = parsed.switches.contains("clear-toggle")
    let hasSearchToggle = parsed.values["search-toggle"] != nil
    let clearSearchToggle = parsed.switches.contains("clear-search-toggle")
    let showDisabled = parsed.switches.contains("show-disabled")
    let hideDisabled = parsed.switches.contains("hide-disabled")
    let dim = parsed.switches.contains("dim")
    let noDim = parsed.switches.contains("no-dim")
    let reset = parsed.switches.contains("reset")
    let dryRun = parsed.switches.contains("dry-run")

    if hasToggle && clearToggle {
        throw CLIError(message: "pass either `--toggle` or `--clear-toggle`, not both", code: 2)
    }
    if hasSearchToggle && clearSearchToggle {
        throw CLIError(message: "pass either `--search-toggle` or `--clear-search-toggle`, not both", code: 2)
    }
    if showDisabled && hideDisabled {
        throw CLIError(message: "pass either `--show-disabled` or `--hide-disabled`, not both", code: 2)
    }
    if dim && noDim {
        throw CLIError(message: "pass either `--dim` or `--no-dim`, not both", code: 2)
    }

    let anyChangeRequested = reset
        || parsed.values["triggers"] != nil
        || parsed.values["delay"] != nil
        || hasToggle
        || clearToggle
        || hasSearchToggle
        || clearSearchToggle
        || showDisabled
        || hideDisabled
        || dim
        || noDim

    guard anyChangeRequested else {
        throw CLIError(
            message: "no peek options specified",
            code: 2,
            hint: "pass --triggers, --delay, --toggle, --clear-toggle, --search-toggle, --clear-search-toggle, --show-disabled, --hide-disabled, --dim, --no-dim, or --reset"
        )
    }

    var parsedTriggers: [Modifier]?
    if let rawTriggers = parsed.values["triggers"] {
        do {
            parsedTriggers = try PeekConfig.parseTriggerList(rawTriggers)
        } catch {
            throw CLIError(message: error.localizedDescription, code: 2)
        }
    }

    var parsedDelay: Int?
    if let rawDelay = parsed.values["delay"] {
        guard let value = Int(rawDelay) else {
            throw CLIError(
                message: "invalid --delay '\(rawDelay)' (expected integer \(PeekConfig.minDelayMilliseconds)...\(PeekConfig.maxDelayMilliseconds) ms)",
                code: 2
            )
        }
        guard (PeekConfig.minDelayMilliseconds...PeekConfig.maxDelayMilliseconds).contains(value) else {
            throw CLIError(
                message: "--delay \(value) is out of range (expected \(PeekConfig.minDelayMilliseconds)...\(PeekConfig.maxDelayMilliseconds) ms)",
                code: 4
            )
        }
        parsedDelay = value
    }

    var parsedToggle: KeyTarget?
    if let rawToggle = parsed.values["toggle"] {
        do {
            parsedToggle = try KeyTarget.parse(rawToggle)
        } catch {
            throw CLIError(message: "invalid --toggle '\(rawToggle)': \(error.localizedDescription)", code: 2)
        }
    }

    var parsedSearchToggle: KeyTarget?
    if let rawSearchToggle = parsed.values["search-toggle"] {
        do {
            parsedSearchToggle = try KeyTarget.parse(rawSearchToggle)
        } catch {
            throw CLIError(message: "invalid --search-toggle '\(rawSearchToggle)': \(error.localizedDescription)", code: 2)
        }
    }

    let updatedPeek: PeekConfig = try mutatePeekConfig(dryRun: dryRun) { config in
        if reset {
            config.peek = .default
        }
        if let parsedTriggers {
            config.peek.triggers = parsedTriggers
        }
        if let parsedDelay {
            config.peek.delayMilliseconds = parsedDelay
        }
        if let parsedToggle {
            config.peek.toggle = parsedToggle
        } else if clearToggle {
            config.peek.toggle = nil
        }
        if let parsedSearchToggle {
            config.peek.searchToggle = parsedSearchToggle
        } else if clearSearchToggle {
            config.peek.searchToggle = nil
        }
        if showDisabled {
            config.peek.showDisabled = true
        } else if hideDisabled {
            config.peek.showDisabled = false
        }
        if dim {
            config.peek.dimUnmatched = true
        } else if noDim {
            config.peek.dimUnmatched = false
        }
    }
    let signaled = !dryRun && signalDaemonAfterPeekMutation()

    if wantsJSON(parsed) {
        try emitJSON("peek.set", PeekMutationPayload(
            dryRun: dryRun,
            action: reset ? "reset" : "set",
            peek: PeekConfigSummary(updatedPeek),
            daemonSignaled: signaled
        ))
        return
    }

    let prefix = dryRun ? "dry-run: " : "✓ "
    let triggerText = updatedPeek.triggers.isEmpty ? "none" : updatedPeek.triggers.map(\.token).joined(separator: ",")
    let toggleText = updatedPeek.toggle?.canonical ?? "none"
    let searchToggleText = updatedPeek.searchToggle?.canonical ?? "none"
    print("\(prefix)peek updated (triggers=\(triggerText), delay=\(updatedPeek.delayMilliseconds)ms, toggle=\(toggleText), searchToggle=\(searchToggleText), dimUnmatched=\(updatedPeek.dimUnmatched), showDisabled=\(updatedPeek.showDisabled))")
    if !updatedPeek.enabled && !reset {
        print("  note: peek overlay is disabled by default; run `hotkeyd peek enable` to turn it on")
    }
}

// MARK: - Helpers

private func loadConfigForPeekRead() throws -> Config {
    do {
        let config = try Config.load(from: Paths.config)
        try config.validate()
        return config
    } catch ConfigError.fileMissing {
        return Config()
    } catch let error as ConfigError {
        let code: Int32
        switch error {
        case .insecureConfig, .fileMissing:
            code = 7
        default:
            code = 4
        }
        throw CLIError(message: error.localizedDescription, code: code)
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }
}

private func mutatePeekConfig(
    dryRun: Bool,
    _ mutate: (inout Config) throws -> Void
) throws -> PeekConfig {
    do {
        if dryRun {
            var config = try loadConfigForEditing()
            try mutate(&config)
            try config.validate()
            return config.peek
        }
        return try Config.withExclusiveLock(for: Paths.config) {
            var config = try loadConfigForEditing()
            try mutate(&config)
            try config.validate()
            try config.save(to: Paths.config)
            return config.peek
        }
    } catch let error as CLIError {
        throw error
    } catch let error as ConfigError {
        let code: Int32
        switch error {
        case .insecureConfig, .fileMissing:
            code = 7
        default:
            code = 4
        }
        throw CLIError(message: error.localizedDescription, code: code)
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }
}

private func signalDaemonAfterPeekMutation() -> Bool {
    guard !Paths.isEnvironmentOverrideActive else { return false }
    guard LaunchAgent.isLoaded(), LaunchAgent.pid() != nil else { return false }
    notifyDaemonToReload()
    return true
}
