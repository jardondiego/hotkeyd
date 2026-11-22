import CoreGraphics
import Darwin
import Foundation
import HotkeydCore

let version = "0.1.0"

struct CLIError: Error {
    let message: String
    let code: Int32
    let kind: String?
    let hint: String?

    init(message: String, code: Int32, kind: String? = nil, hint: String? = nil) {
        self.message = message
        self.code = code
        self.kind = kind
        self.hint = hint
    }

    var resolvedKind: String {
        if let kind { return kind }
        switch code {
        case 2: return "usage"
        case 3: return "not_found"
        case 4: return "validation"
        case 5: return "permission"
        case 6: return "daemon"
        case 7: return "config_io"
        case 8: return "action_failed"
        default: return "error"
        }
    }
}

// MARK: - Entry point

func dispatch(_ arguments: [String]) throws {
    guard let command = arguments.first else {
        print(usage())
        return
    }
    let rest = Array(arguments.dropFirst())

    switch command {
    case "init": try commandInit(rest)
    case "add": try commandAdd(rest, force: false)
    case "set": try commandAdd(rest, force: true)
    case "list", "ls": try commandList(rest)
    case "show": try commandShow(rest)
    case "remove", "rm": try commandRemove(rest)
    case "enable": try commandSetEnabled(rest, enabled: true)
    case "disable": try commandSetEnabled(rest, enabled: false)
    case "validate": try commandValidate(rest)
    case "edit": try commandEdit(rest)
    case "run": try commandRun(rest)
    case "migrate-actions": try commandMigrateActions(rest)
    case "caps": try commandCaps(rest)
    case "peek": try commandPeek(rest)
    case "daemon": try commandDaemon(rest)
    case "pause": try commandPause(rest)
    case "resume": try commandResume(rest)
    case "panic": try commandPanic(rest)
    case "status": try commandStatus(rest)
    case "logs": try commandLogs(rest)
    case "stats": try commandStats(rest)
    case "doctor": try commandDoctor(rest)
    case "describe": try commandDescribe(rest)
    case "schema": try commandSchema(rest)
    case "completions": try commandCompletions(rest)
    case "man": try commandMan(rest)
    case "__complete": try commandInternalComplete(rest)
    case "__peek-overlay": try commandInternalPeekOverlay(rest)
    case "version", "--version", "-v": try commandVersion(rest)
    case "help", "--help", "-h": try commandHelp(rest)
    default:
        let preDash = arguments.prefix(while: { $0 != "--" })
        let wantsJson = preDash.contains { arg in
            let lower = arg.lowercased()
            return lower == "--json" || lower == "--json=true" || lower == "--json=1"
        }
        let message = wantsJson
            ? "unknown command '\(command)'"
            : "unknown command '\(command)'\n\n\(usage())"
        throw CLIError(
            message: message,
            code: 2,
            hint: "run `hotkeyd help` or `hotkeyd describe --json` for available commands"
        )
    }
}

struct HelpPayload: Encodable {
    let target: String?
    let text: String
    let command: CommandSpec?
}

func commandHelp(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"], positionals: 2)
    let target = parsed.positionals
    if target.isEmpty {
        let text = usage()
        if wantsJSON(parsed) {
            try emitJSON("help", HelpPayload(target: nil, text: text, command: nil))
        } else {
            print(text)
        }
        return
    }
    if let spec = CommandRegistry.findCommand(matching: target) {
        let text = CommandRegistry.formatHelp(for: spec)
        if wantsJSON(parsed) {
            try emitJSON("help", HelpPayload(target: spec.displayName, text: text, command: spec))
        } else {
            print(text)
        }
        return
    }
    if target.count == 1, let groupHelp = CommandRegistry.formatGroupHelp(group: target[0]) {
        if wantsJSON(parsed) {
            try emitJSON("help", HelpPayload(target: target[0], text: groupHelp, command: nil))
        } else {
            print(groupHelp)
        }
        return
    }
    throw CLIError(
        message: "unknown command '\(target.joined(separator: " "))'",
        code: 2,
        hint: "run `hotkeyd help` for available commands"
    )
}

func printCommandHelp(_ path: [String]) {
    if let spec = CommandRegistry.findCommand(matching: path) {
        print(CommandRegistry.formatHelp(for: spec))
    } else if path.count == 1, let groupHelp = CommandRegistry.formatGroupHelp(group: path[0]) {
        print(groupHelp)
    } else {
        print(usage())
    }
}

func usage() -> String {
    """
    hotkeyd \(version) — global shortcuts for macOS

    USAGE
      hotkeyd <command> [options]
      hotkeyd help <command>

    SETUP
      init [--starter <minimal|empty|skip>] [--no-daemon] [--no-open] [--no-verify]
          [--allow-adhoc] [--dry-run] [--non-interactive] [--json]
      completions <zsh|bash|fish> [--install] [--json]
      man [--install] [--json]              generate or install man hotkeyd (hotkeyd.1)

    SHORTCUTS
      add <keys> [command] [--tap <cmd>] [--double-tap <cmd>] [--force] [--dry-run]
          [--name <name>] [--max-double-tap-delay <ms>] [--max-sequence-delay <ms>]
          [--timeout <ms>] [--cwd <dir>] [--pass-through] [--allow-accessibility] [--json]
      set <keys|name> [command] [--tap <cmd>] [--double-tap <cmd>] [--name <name>]
          [--timeout <ms>] [--cwd <dir>] [--clear-name|--clear-cwd|--clear-timeout|--clear-delays]
          [--dry-run] [--json]
      list (ls) [--full] [--json]
      show <keys|name> [--json]
      remove (rm) <keys|name> [--tap | --double-tap] [--dry-run] [--json]
      enable <keys|name> [--dry-run] [--json]
      disable <keys|name> [--dry-run] [--json]
      validate [--json]
      edit                                  edit ~/.hotkeyd safely with pre-save validation
      run <keys|name> [--tap | --double-tap] [--wait] [--json]

    DAEMON
      daemon status [--json]
      daemon start [--json]
      daemon stop [--json]
      daemon reload [--json]                SIGHUP running daemon to reload ~/.hotkeyd
      daemon restart [--json]
      daemon logs [--lines <n>] [--daemon] [--actions] [--follow|-f] [--utc] [--json]
      daemon install [--binary <path>] [--no-open] [--json]
      daemon uninstall [--json]
      daemon run                            foreground, used by launchd
      pause [--for <duration>] [--reason <text>] [--toggle] [--json]
      resume [--json]                       re-arm shortcuts after `hotkeyd pause`
      panic [--json]                        stop daemon & restore Caps Lock immediately

    CAPS LOCK
      caps status [--json]
      caps on [--json]                      remap Caps Lock to F18 so capsLock bindings work
      caps off [--json]                     restore Caps Lock
      caps reset [--json]                   force the Caps Lock state off (safe while remapped)

    PEEK OVERLAY
      peek [--search] [--terminal] [--query <text>] [--show-disabled] [--json]
                                            toggle cheatsheet/search HUD (or print CLI card)
      peek status [--json]                  inspect hold triggers, delay, and toggle hotkeys
      peek enable | disable [--dry-run] [--json]
      peek set [--triggers <list>] [--delay <ms>] [--toggle <keys>|--clear-toggle]
          [--search-toggle <keys>|--clear-search-toggle] [--dim|--no-dim]
          [--show-disabled|--hide-disabled] [--reset] [--dry-run] [--json]

    DIAGNOSTICS & INTROSPECTION
      status [--json]
      logs [--lines <n>] [--daemon] [--actions] [--follow|-f] [--utc] [--json]
      stats [--since <window>] [--top <n>] [--unused] [--json]
      doctor [--json]
      describe [--json]                     full machine manifest of commands, flags, keys & exit codes
      schema [config|shortcut] [--json]     JSON Schema (draft 2020-12) for ~/.hotkeyd
      version [--json]

    FILES
      config   \(Paths.config.path)
      logs     \(Paths.logs.path)
      override the state directory with HOTKEYD_HOME

    EXAMPLES
      hotkeyd add lcmd 'open -a "Google Chrome"'
      hotkeyd add fn+space 'open -a Notes'
      hotkeyd add fn:q 'open -a Safari'
      hotkeyd add fn+escape --tap 'osascript -e "set volume output muted true"' \\
                             --double-tap 'osascript -e "set volume output volume 100"'
      hotkeyd set fn+space --name 'Notes' --timeout 15000
      hotkeyd show fn+space
      hotkeyd daemon install
      hotkeyd doctor
    """
}

// MARK: - Arguments

struct ParsedArguments {
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var explicitFalseSwitches: Set<String> = []
    var positionals: [String] = []
}

func parseBooleanFlagValue(_ raw: String, flagName: String) throws -> Bool {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "true", "1", "yes":
        return true
    case "false", "0", "no":
        return false
    default:
        throw CLIError(
            message: "boolean option '--\(flagName)' expects true or false (got '\(raw)')",
            code: 2
        )
    }
}

func parseArguments(
    _ arguments: [String],
    valued: Set<String>,
    switches: Set<String>,
    positionals allowedPositionals: Int = 0
) throws -> ParsedArguments {
    let preDoubleDash = arguments.prefix(while: { $0 != "--" })
    if switches.contains("help"),
       preDoubleDash.contains(where: { arg in
           let lower = arg.lowercased()
           return lower == "--help" || lower == "-h" || lower == "--help=true" || lower == "--help=1"
       }) {
        return ParsedArguments(switches: ["help"])
    }
    var parsed = ParsedArguments()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            parsed.positionals.append(contentsOf: arguments[(index + 1)...])
            break
        }
        if argument == "-f" {
            if switches.contains("force") {
                parsed.switches.insert("force")
                index += 1
                continue
            }
            if switches.contains("follow") {
                parsed.switches.insert("follow")
                index += 1
                continue
            }
        }
        if argument.hasPrefix("--") {
            let body = String(argument.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            if switches.contains(name) {
                if parts.count == 2 {
                    let flagValue = try parseBooleanFlagValue(parts[1], flagName: name)
                    if flagValue {
                        parsed.switches.insert(name)
                        parsed.explicitFalseSwitches.remove(name)
                    } else {
                        parsed.switches.remove(name)
                        parsed.explicitFalseSwitches.insert(name)
                    }
                } else {
                    parsed.switches.insert(name)
                    parsed.explicitFalseSwitches.remove(name)
                }
                index += 1
                continue
            }
            guard valued.contains(name) else {
                throw CLIError(message: "unknown option '--\(name)'", code: 2)
            }
            let value: String
            if parts.count == 2 {
                value = parts[1]
                index += 1
            } else {
                guard index + 1 < arguments.count else {
                    throw CLIError(message: "option '--\(name)' needs a value", code: 2)
                }
                value = arguments[index + 1]
                index += 2
            }
            parsed.values[name] = value
            continue
        }
        if argument.hasPrefix("-") && argument != "-" {
            throw CLIError(message: "unknown option '\(argument)'", code: 2)
        }
        parsed.positionals.append(argument)
        index += 1
    }
    if parsed.positionals.count > allowedPositionals {
        throw CLIError(
            message: "unexpected argument '\(parsed.positionals[allowedPositionals])'",
            code: 2
        )
    }
    return parsed
}

func loadConfigForEditing() throws -> Config {
    do {
        return try Config.load(from: Paths.config)
    } catch ConfigError.fileMissing {
        return Config()
    }
}

// MARK: - Output & Formatting

struct Envelope<Payload: Encodable>: Encodable {
    let ok: Bool
    let schemaVersion = "1"
    let command: String
    let data: Payload

    init(ok: Bool = true, command: String, data: Payload) {
        self.ok = ok
        self.command = command
        self.data = data
    }
}

struct ErrorDetail: Encodable {
    let code: Int32
    let kind: String
    let message: String
    let hint: String?
}

struct ErrorEnvelope: Encodable {
    let ok = false
    let schemaVersion = "1"
    let error: ErrorDetail
}

/// Explicit JSON representation of a shortcut so CLI consumers always see explicit boolean fields
/// (`enabled`, `passThrough`, `allowAccessibility`, `usesSelectedText`) and `executionMode`.
struct ShortcutView: Encodable {
    let keys: String
    let tap: String?
    let doubleTap: String?
    let name: String?
    let enabled: Bool
    let passThrough: Bool
    let allowAccessibility: Bool
    let maxDoubleTapDelayMs: Int?
    let maxSequenceDelayMs: Int?
    let timeoutMs: Int?
    let cwd: String?
    let executionMode: String
    let usesSelectedText: Bool

    init(_ shortcut: Shortcut) {
        self.keys = shortcut.keys.canonical
        self.tap = shortcut.tap
        self.doubleTap = shortcut.doubleTap
        self.name = shortcut.name
        self.enabled = shortcut.enabled
        self.passThrough = shortcut.passThrough
        self.allowAccessibility = shortcut.allowAccessibility
        self.maxDoubleTapDelayMs = shortcut.maxDoubleTapDelayMilliseconds
        self.maxSequenceDelayMs = shortcut.maxSequenceDelayMilliseconds
        self.timeoutMs = shortcut.timeoutMilliseconds
        self.cwd = shortcut.cwd
        self.executionMode = shortcut.primaryExecutionMode
        self.usesSelectedText = shortcut.usesSelectedText
    }
}

func emitJSON<Payload: Encodable>(_ command: String, _ payload: Payload, ok: Bool = true) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(Envelope(ok: ok, command: command, data: payload))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func emitErrorJSON(code: Int32, kind: String = "error", message: String, hint: String? = nil) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let detail = ErrorDetail(code: code, kind: kind, message: message, hint: hint)
    if let data = try? encoder.encode(ErrorEnvelope(error: detail)) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        FileHandle.standardError.write(Data(("hotkeyd: \(message)\n").utf8))
    }
}

func wantsJSON(_ arguments: ParsedArguments) -> Bool {
    arguments.switches.contains("json")
}

func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}

func terminalColumns() -> Int {
    var ws = winsize()
    if isatty(STDOUT_FILENO) == 1, ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 20 {
        return Int(ws.ws_col)
    }
    return 108
}

func formatCommandPreview(_ raw: String, maxWidth: Int) -> String {
    let cleaned = Log.sanitizeMessage(raw)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard maxWidth >= 8, cleaned.count > maxWidth else { return cleaned }
    return String(cleaned.prefix(maxWidth - 1)) + "…"
}

func compactFlagsLabel(for shortcut: Shortcut) -> String {
    var badges: [String] = []
    if !shortcut.enabled { badges.append("disabled") }
    if shortcut.allowAccessibility { badges.append("AX") }
    if shortcut.passThrough { badges.append("pass") }
    return badges.joined(separator: ",")
}

// MARK: - Target Matching

private func matchesTarget(_ shortcut: Shortcut, target: String) -> Bool {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if let parsedKey = try? KeyTarget.parse(trimmed), shortcut.keys == parsedKey {
        return true
    }
    if shortcut.keys.canonical.caseInsensitiveCompare(trimmed) == .orderedSame {
        return true
    }
    if shortcut.trigger.display.caseInsensitiveCompare(trimmed) == .orderedSame {
        return true
    }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("doubletap:") {
        let tail = String(trimmed.dropFirst("doubletap:".count))
        if let mod = Modifier.parse(tail), shortcut.keys == .modifier(mod) {
            return true
        }
        if let combo = try? KeyCombo.parse(tail), shortcut.keys == .combo(combo) {
            return true
        }
    } else if lower.hasPrefix("doubletapkeys:") {
        let tail = String(trimmed.dropFirst("doubletapkeys:".count))
        if let combo = try? KeyCombo.parse(tail), shortcut.keys == .combo(combo) {
            return true
        }
    }
    if let name = shortcut.name, name.caseInsensitiveCompare(trimmed) == .orderedSame {
        return true
    }
    return false
}

private func findUniqueShortcutIndex(in config: Config, target: String) throws -> Int {
    let matchingIndices = config.shortcuts.indices.filter {
        matchesTarget(config.shortcuts[$0], target: target)
    }
    guard let index = matchingIndices.first else {
        throw CLIError(
            message: "no shortcut matching '\(target)'",
            code: 3,
            hint: "run `hotkeyd list` to see configured shortcuts"
        )
    }
    guard matchingIndices.count == 1 else {
        let labels = matchingIndices.map { config.shortcuts[$0].displayName }.joined(separator: ", ")
        throw CLIError(message: "'\(target)' is ambiguous: \(labels)", code: 4)
    }
    return index
}

// MARK: - add & set

struct DryRunMutationPayload: Encodable {
    let dryRun = true
    let action: String
    let shortcut: ShortcutView
    let warnings: [String]
}

func commandAdd(_ arguments: [String], force: Bool = false) throws {
    let commandVerb = force ? "set" : "add"
    var allowedSwitches: Set<String> = [
        "json", "help", "dry-run", "pass-through", "no-pass-through",
        "allow-accessibility", "no-allow-accessibility", "force", "upsert"
    ]
    if force {
        allowedSwitches.formUnion(["clear-name", "clear-cwd", "clear-timeout", "clear-delays"])
    }
    let parsed = try parseArguments(
        arguments,
        valued: [
            "keys", "tap", "double-tap", "double-tap-keys",
            "shell", "app", "url", "name",
            "max-double-tap-delay", "max-sequence-delay", "window",
            "timeout", "cwd"
        ],
        switches: allowedSwitches,
        positionals: 2
    )
    if parsed.switches.contains("help") {
        printCommandHelp([commandVerb])
        return
    }

    let shouldOverwrite = force || parsed.switches.contains("force") || parsed.switches.contains("upsert")
    let dryRun = parsed.switches.contains("dry-run")

    if parsed.values["max-double-tap-delay"] != nil && parsed.values["window"] != nil {
        throw CLIError(
            message: "specify either --max-double-tap-delay or legacy --window, not both",
            code: 2
        )
    }

    var maxDoubleTapDelayMilliseconds: Int?
    if let raw = parsed.values["max-double-tap-delay"] ?? parsed.values["window"] {
        let flagName = parsed.values["max-double-tap-delay"] != nil ? "--max-double-tap-delay" : "--window"
        guard let value = Int(raw) else {
            throw CLIError(message: "\(flagName) must be an integer number of milliseconds", code: 2)
        }
        guard (100...600).contains(value) else {
            throw CLIError(message: "\(flagName) must be between 100 and 600 ms", code: 4)
        }
        maxDoubleTapDelayMilliseconds = value
    }

    var maxSequenceDelayMilliseconds: Int?
    if let raw = parsed.values["max-sequence-delay"] {
        guard let value = Int(raw) else {
            throw CLIError(message: "--max-sequence-delay must be an integer number of milliseconds", code: 2)
        }
        guard (100...1500).contains(value) else {
            throw CLIError(message: "--max-sequence-delay must be between 100 and 1500 ms", code: 4)
        }
        maxSequenceDelayMilliseconds = value
    }

    var timeoutMilliseconds: Int?
    if let raw = parsed.values["timeout"] {
        guard let value = Int(raw) else {
            throw CLIError(message: "--timeout must be an integer number of milliseconds", code: 2)
        }
        guard (1...600_000).contains(value) else {
            throw CLIError(message: "--timeout must be between 1 and 600000 ms", code: 4)
        }
        timeoutMilliseconds = value
    }

    if let cwd = parsed.values["cwd"], Paths.resolveWorkingDirectory(cwd) == nil {
        throw CLIError(message: "--cwd must resolve to an absolute path or '~'", code: 4)
    }

    let allowAccessibility = parsed.switches.contains("allow-accessibility")
    let revokeAccessibility = parsed.switches.contains("no-allow-accessibility")
        || parsed.explicitFalseSwitches.contains("allow-accessibility")
    if allowAccessibility && revokeAccessibility {
        throw CLIError(
            message: "specify either --allow-accessibility or --no-allow-accessibility, not both",
            code: 2
        )
    }
    let passThrough = parsed.switches.contains("pass-through")
    let revokePassThrough = parsed.switches.contains("no-pass-through")
        || parsed.explicitFalseSwitches.contains("pass-through")
    if passThrough && revokePassThrough {
        throw CLIError(
            message: "specify either --pass-through or --no-pass-through, not both",
            code: 2
        )
    }

    let clearName = parsed.switches.contains("clear-name")
    let clearCwd = parsed.switches.contains("clear-cwd")
    let clearTimeout = parsed.switches.contains("clear-timeout")
    let clearDelays = parsed.switches.contains("clear-delays")

    let legacyActionCount = [parsed.values["shell"], parsed.values["app"], parsed.values["url"]]
        .compactMap { $0 }.count

    // Metadata-only update via `hotkeyd set <keys|name> --name ... --timeout ...` (without
    // re-supplying commands). Preserves existing commands and flags unless explicitly changed.
    let hasAnyMetadataMutation = parsed.values["name"] != nil
        || maxDoubleTapDelayMilliseconds != nil
        || maxSequenceDelayMilliseconds != nil
        || timeoutMilliseconds != nil
        || parsed.values["cwd"] != nil
        || passThrough || revokePassThrough
        || allowAccessibility || revokeAccessibility
        || clearName || clearCwd || clearTimeout || clearDelays

    if force,
       legacyActionCount == 0,
       parsed.values["tap"] == nil,
       parsed.values["double-tap"] == nil,
       parsed.positionals.count <= 1,
       hasAnyMetadataMutation {
        let rawTarget: String
        if let flagKeys = parsed.values["keys"] {
            guard parsed.positionals.isEmpty else {
                throw CLIError(message: "specify keys either positionally or with --keys, not both", code: 2)
            }
            rawTarget = flagKeys
        } else if let first = parsed.positionals.first {
            rawTarget = first
        } else {
            throw CLIError(message: "set needs <keys|name> to identify the shortcut to update", code: 2)
        }

        let (updatedShortcut, warnings) = try Config.withExclusiveLock(for: Paths.config) { () -> (Shortcut, [String]) in
            var config: Config
            do {
                config = try loadConfigForEditing()
            } catch {
                throw CLIError(message: error.localizedDescription, code: 7)
            }
            let index = try findUniqueShortcutIndex(in: config, target: rawTarget)
            var existing = config.shortcuts[index]

            if clearName {
                existing.name = nil
            } else if let rawName = parsed.values["name"] {
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw CLIError(message: "--name must not be empty (use --clear-name to remove it)", code: 2)
                }
                existing.name = trimmed
            }
            if clearCwd {
                existing.cwd = nil
            } else if let cwd = parsed.values["cwd"] {
                existing.cwd = cwd
            }
            if clearTimeout {
                existing.timeoutMilliseconds = nil
            } else if let timeout = timeoutMilliseconds {
                existing.timeoutMilliseconds = timeout
            }
            if clearDelays {
                existing.maxDoubleTapDelayMilliseconds = nil
                existing.maxSequenceDelayMilliseconds = nil
            } else {
                if let dtDelay = maxDoubleTapDelayMilliseconds {
                    existing.maxDoubleTapDelayMilliseconds = dtDelay
                }
                if let seqDelay = maxSequenceDelayMilliseconds {
                    existing.maxSequenceDelayMilliseconds = seqDelay
                }
            }
            if passThrough { existing.passThrough = true }
            if revokePassThrough { existing.passThrough = false }
            if allowAccessibility { existing.allowAccessibility = true }
            if revokeAccessibility { existing.allowAccessibility = false }

            config.shortcuts[index] = existing
            do {
                try config.validate()
            } catch {
                throw CLIError(message: error.localizedDescription, code: 4)
            }
            let warnings = config.rolloverWarnings()
            if !dryRun {
                do {
                    try config.save(to: Paths.config)
                } catch {
                    throw CLIError(message: error.localizedDescription, code: 7)
                }
            }
            return (existing, warnings)
        }
        if !dryRun {
            notifyDaemonToReload()
        }
        if wantsJSON(parsed) {
            if dryRun {
                try emitJSON("set", DryRunMutationPayload(action: "update", shortcut: ShortcutView(updatedShortcut), warnings: warnings))
            } else {
                try emitJSON("set", ShortcutView(updatedShortcut))
            }
            return
        }
        let verb = dryRun ? "[dry-run] would update" : "updated"
        print("\(verb) \(updatedShortcut.keys.canonical)" + (updatedShortcut.name.map { " (\($0))" } ?? ""))
        print("  config:    \(Paths.config.path)")
        return
    }

    let keysTarget: KeyTarget
    var tapCommand: String?
    var doubleTapCommand: String?

    if legacyActionCount > 0 {
        guard legacyActionCount == 1 else {
            throw CLIError(
                message: "\(commandVerb) needs at most one of --shell, --app or --url",
                code: 2
            )
        }
        let commandString: String
        if let shell = parsed.values["shell"] {
            guard !shell.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIError(message: "\(commandVerb) needs a non-empty --shell '<command>'", code: 2)
            }
            commandString = shell
        } else if let app = parsed.values["app"] {
            let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\0") else {
                throw CLIError(message: "\(commandVerb) needs a non-empty --app '<name|bundle-id|path>'", code: 2)
            }
            commandString = Action.app(target: trimmed).shellCommandString
        } else if let rawURL = parsed.values["url"] {
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Action.validatedWebURL(trimmed) != nil else {
                throw CLIError(
                    message: "invalid or unsafe URL '\(rawURL)'; only http:// and https:// URLs with a host are allowed",
                    code: 4
                )
            }
            commandString = Action.url(trimmed).shellCommandString
        } else {
            throw CLIError(message: "unreachable", code: 2)
        }

        let gestureValue = parsed.values["double-tap"]
        let doubleTapKeysValue = parsed.values["double-tap-keys"]
        let keysValue = parsed.values["keys"] ?? parsed.positionals.first
        let triggerCount = [gestureValue, doubleTapKeysValue, keysValue].compactMap { $0 }.count
        guard triggerCount == 1 else {
            throw CLIError(
                message: "\(commandVerb) needs <keys> or --keys <modifier|combo|sequence>",
                code: 2
            )
        }
        if let gestureValue {
            guard let modifier = Modifier.parse(gestureValue) else {
                throw CLIError(
                    message: "unknown modifier '\(gestureValue)'; use cmd/opt/ctrl/shift/fn/capsLock, optionally with l/r (lcmd, ropt, ...)",
                    code: 2
                )
            }
            keysTarget = .modifier(modifier)
            doubleTapCommand = commandString
        } else if let doubleTapKeysValue {
            do {
                keysTarget = .combo(try KeyCombo.parse(doubleTapKeysValue))
                doubleTapCommand = commandString
            } catch {
                throw CLIError(message: error.localizedDescription, code: 4)
            }
        } else if let keysValue {
            do {
                let parsedTarget = try KeyTarget.parse(keysValue)
                if case .modifier(let modifier) = parsedTarget {
                    throw CLIError(
                        message: "modifier '\(modifier.token)' only supports --double-tap; single modifier presses cannot be bound",
                        code: 4
                    )
                }
                keysTarget = parsedTarget
                tapCommand = commandString
            } catch let cliError as CLIError {
                throw cliError
            } catch {
                throw CLIError(message: error.localizedDescription, code: 4)
            }
        } else {
            throw CLIError(message: "unreachable", code: 2)
        }
    } else {
        let rawKeys: String
        let positionalCommand: String?

        if let flagKeys = parsed.values["keys"] {
            rawKeys = flagKeys
            if parsed.positionals.count == 1 && parsed.values["tap"] == nil && parsed.values["double-tap"] == nil {
                positionalCommand = parsed.positionals[0]
            } else if !parsed.positionals.isEmpty {
                throw CLIError(
                    message: "specify keys either positionally or with --keys, not both",
                    code: 2
                )
            } else {
                positionalCommand = nil
            }
        } else {
            guard let firstPositional = parsed.positionals.first else {
                throw CLIError(
                    message: "\(commandVerb) needs <keys> (e.g. `hotkeyd \(commandVerb) lcmd 'open -a Chrome'` or `hotkeyd \(commandVerb) fn:q 'open -a Safari'`)",
                    code: 2
                )
            }
            rawKeys = firstPositional
            positionalCommand = parsed.positionals.count > 1 ? parsed.positionals[1] : nil
        }

        do {
            keysTarget = try KeyTarget.parse(rawKeys)
        } catch {
            throw CLIError(message: error.localizedDescription, code: 4)
        }

        tapCommand = parsed.values["tap"]
        doubleTapCommand = parsed.values["double-tap"]

        if let positionalCommand {
            if tapCommand != nil || doubleTapCommand != nil {
                throw CLIError(
                    message: "pass a command either positionally or with --tap/--double-tap, not both",
                    code: 2
                )
            }
            switch keysTarget {
            case .modifier:
                doubleTapCommand = positionalCommand
            case .combo, .sequence:
                tapCommand = positionalCommand
            }
        }

        if tapCommand == nil && doubleTapCommand == nil {
            throw CLIError(
                message: "\(commandVerb) needs a command (pass `<command>` positionally, or `--tap '<command>'` / `--double-tap '<command>'`)",
                code: 2
            )
        }
        if let tap = tapCommand, tap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "tap '<command>' must not be empty", code: 2)
        }
        if let dt = doubleTapCommand, dt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "double-tap '<command>' must not be empty", code: 2)
        }
    }

    if case .modifier(let modifier) = keysTarget {
        if tapCommand != nil {
            throw CLIError(
                message: "modifier '\(modifier.token)' only supports --double-tap; single modifier presses cannot be bound",
                code: 4
            )
        }
        if passThrough {
            throw CLIError(
                message: "--pass-through only applies to key combinations and sequences; modifier gestures consume nothing",
                code: 2
            )
        }
    }
    if case .sequence = keysTarget, doubleTapCommand != nil {
        throw CLIError(
            message: "sequence '\(keysTarget.canonical)' only supports --tap; --double-tap is not supported on sequences",
            code: 4
        )
    }
    if maxDoubleTapDelayMilliseconds != nil, doubleTapCommand == nil {
        let usedLegacyWindow = parsed.values["window"] != nil
        if usedLegacyWindow, case .sequence = keysTarget {
            throw CLIError(
                message: "--window only applies to double-tap bindings; use --max-sequence-delay for '<modifier> > <key>' sequences",
                code: 2
            )
        }
        let flagName = usedLegacyWindow ? "--window" : "--max-double-tap-delay"
        throw CLIError(message: "\(flagName) only applies when --double-tap is set", code: 2)
    }
    if maxSequenceDelayMilliseconds != nil, keysTarget.sequence == nil {
        throw CLIError(
            message: "--max-sequence-delay only applies to '<modifier> > <key>' sequences",
            code: 2
        )
    }

    let explicitName = parsed.values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let shortcut = Shortcut(
        keys: keysTarget,
        tap: tapCommand,
        doubleTap: doubleTapCommand,
        name: (explicitName?.isEmpty == false) ? explicitName : nil,
        enabled: true,
        passThrough: passThrough,
        allowAccessibility: allowAccessibility,
        maxDoubleTapDelayMilliseconds: maxDoubleTapDelayMilliseconds,
        maxSequenceDelayMilliseconds: maxSequenceDelayMilliseconds,
        timeoutMilliseconds: timeoutMilliseconds,
        cwd: parsed.values["cwd"]
    )

    let (savedShortcut, updatedExistingSlot, warnings) = try Config.withExclusiveLock(for: Paths.config) { () -> (Shortcut, Bool, [String]) in
        var config: Config
        do {
            config = try loadConfigForEditing()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 7)
        }

        if let name = shortcut.name,
           let conflict = config.shortcuts.first(where: { $0.name?.caseInsensitiveCompare(name) == .orderedSame }),
           conflict.keys != keysTarget {
            throw CLIError(message: "a shortcut named '\(name)' already exists", code: 4)
        }

        var resultShortcut = shortcut
        var overwritten = false
        // Match enabled entry first, falling back to a disabled entry on the same keys so `set`
        // updates in place rather than appending unremovable duplicates.
        let existingIndex = config.shortcuts.firstIndex(where: { $0.enabled && $0.keys == keysTarget })
            ?? config.shortcuts.firstIndex(where: { $0.keys == keysTarget })

        if let existingIndex {
            var existing = config.shortcuts[existingIndex]
            let retainedOtherTap = (shortcut.tap == nil && existing.tap != nil)
            let retainedOtherDoubleTap = (shortcut.doubleTap == nil && existing.doubleTap != nil)
            let replacedAllActiveSlots = !retainedOtherTap && !retainedOtherDoubleTap

            if shortcut.tap != nil && existing.tap != nil {
                if !shouldOverwrite {
                    throw CLIError(
                        message: "\(keysTarget.canonical) (tap) is already bound (pass --force or use `hotkeyd set` to overwrite)",
                        code: 4
                    )
                }
                overwritten = true
            }
            if shortcut.doubleTap != nil && existing.doubleTap != nil {
                if !shouldOverwrite {
                    throw CLIError(
                        message: "\(keysTarget.canonical) (doubleTap) is already bound (pass --force or use `hotkeyd set` to overwrite)",
                        code: 4
                    )
                }
                overwritten = true
            }
            if let tap = shortcut.tap { existing.tap = tap }
            if let dt = shortcut.doubleTap { existing.doubleTap = dt }
            if clearName { existing.name = nil }
            else if let name = shortcut.name { existing.name = name }
            if clearDelays {
                existing.maxDoubleTapDelayMilliseconds = nil
                existing.maxSequenceDelayMilliseconds = nil
            } else {
                if let dtDelay = shortcut.maxDoubleTapDelayMilliseconds {
                    existing.maxDoubleTapDelayMilliseconds = dtDelay
                }
                if let seqDelay = shortcut.maxSequenceDelayMilliseconds {
                    existing.maxSequenceDelayMilliseconds = seqDelay
                }
            }
            if clearTimeout { existing.timeoutMilliseconds = nil }
            else if let timeout = shortcut.timeoutMilliseconds { existing.timeoutMilliseconds = timeout }
            if clearCwd { existing.cwd = nil }
            else if let cwd = shortcut.cwd { existing.cwd = cwd }

            if revokePassThrough {
                existing.passThrough = false
            } else if shortcut.passThrough {
                existing.passThrough = true
            } else if replacedAllActiveSlots {
                existing.passThrough = false
            }

            if revokeAccessibility {
                existing.allowAccessibility = false
            } else if shortcut.allowAccessibility {
                existing.allowAccessibility = true
            } else if replacedAllActiveSlots {
                existing.allowAccessibility = false
            }

            config.shortcuts[existingIndex] = existing
            resultShortcut = existing
        } else {
            config.shortcuts.append(shortcut)
        }

        do {
            try config.validate()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 4)
        }
        let warnings = config.rolloverWarnings()
        if !dryRun {
            do {
                try config.save(to: Paths.config)
            } catch {
                throw CLIError(message: error.localizedDescription, code: 7)
            }
        }
        return (resultShortcut, overwritten, warnings)
    }
    if !dryRun {
        notifyDaemonToReload()
    }

    if wantsJSON(parsed) {
        if dryRun {
            try emitJSON(commandVerb, DryRunMutationPayload(
                action: updatedExistingSlot ? "update" : "add",
                shortcut: ShortcutView(savedShortcut),
                warnings: warnings
            ))
        } else {
            try emitJSON(commandVerb, ShortcutView(savedShortcut))
        }
        return
    }

    let actionWord = dryRun
        ? (updatedExistingSlot ? "[dry-run] would update" : "[dry-run] would add")
        : (updatedExistingSlot ? "updated" : "added")
    print("\(actionWord) \(savedShortcut.keys.canonical)")
    if let tap = savedShortcut.tap {
        let display = (tap.contains("\n") || tap.count > 120) ? formatCommandPreview(tap, maxWidth: 100) : tap
        print("  tap:       \(display)")
    }
    if let dt = savedShortcut.doubleTap {
        let display = (dt.contains("\n") || dt.count > 120) ? formatCommandPreview(dt, maxWidth: 100) : dt
        print("  doubleTap: \(display)")
    }
    print("  config:    \(Paths.config.path)")
    for warning in warnings where warning.contains("'\(savedShortcut.keys.canonical)'") {
        FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
    }
    if !dryRun && !Paths.isEnvironmentOverrideActive {
        if !LaunchAgent.isLoaded() {
            print("")
            print("the daemon is not running yet; install it with:")
            print("  hotkeyd daemon install")
        } else {
            print("  daemon reloads automatically; if it does not, run `hotkeyd daemon reload`")
        }
    }
}

// MARK: - list & show

struct ListPayload: Encodable {
    let configPath: String
    let shortcuts: [ShortcutView]
    let count: Int
}

func commandList(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["full", "json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["list"])
        return
    }

    let config: Config
    do {
        config = try Config.load(from: Paths.config)
    } catch ConfigError.fileMissing {
        config = Config()
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }

    if wantsJSON(parsed) {
        let views = config.shortcuts.map(ShortcutView.init)
        try emitJSON("list", ListPayload(configPath: Paths.config.path, shortcuts: views, count: views.count))
        return
    }

    guard !config.shortcuts.isEmpty else {
        print("no shortcuts yet")
        print("  hotkeyd add lcmd 'open -a Terminal'")
        return
    }

    let full = parsed.switches.contains("full")

    struct Row {
        let keys: String
        let when: String
        let name: String
        let flags: String
        let command: String
    }

    var rows: [Row] = []
    for shortcut in config.shortcuts {
        let nameText = shortcut.name ?? ""
        let flagsText = compactFlagsLabel(for: shortcut)
        if let tap = shortcut.tap {
            rows.append(Row(
                keys: shortcut.keys.canonical,
                when: "tap",
                name: nameText,
                flags: flagsText,
                command: tap
            ))
        }
        if let doubleTap = shortcut.doubleTap {
            rows.append(Row(
                keys: shortcut.keys.canonical,
                when: "doubleTap",
                name: nameText,
                flags: flagsText,
                command: doubleTap
            ))
        }
    }

    let showNameCol = rows.contains { !$0.name.isEmpty }
    let showFlagsCol = rows.contains { !$0.flags.isEmpty }
    let keysWidth = max(10, rows.map(\.keys.count).max() ?? 10)
    let whenWidth = 9 // "doubleTap".count
    let nameWidth = showNameCol ? min(24, max(4, rows.map(\.name.count).max() ?? 4)) : 0
    let flagsWidth = showFlagsCol ? max(5, rows.map(\.flags.count).max() ?? 5) : 0

    var header = "\(pad("KEYS", keysWidth))  \(pad("WHEN", whenWidth))"
    if showNameCol { header += "  \(pad("NAME", nameWidth))" }
    if showFlagsCol { header += "  \(pad("FLAGS", flagsWidth))" }
    header += "  COMMAND"
    print(header)

    let prefixWidth = keysWidth + 2 + whenWidth
        + (showNameCol ? (2 + nameWidth) : 0)
        + (showFlagsCol ? (2 + flagsWidth) : 0)
        + 2
    let commandBudget = max(36, terminalColumns() - prefixWidth)

    for row in rows {
        var line = "\(pad(row.keys, keysWidth))  \(pad(row.when, whenWidth))"
        if showNameCol {
            let trimmedName = row.name.count > nameWidth
                ? String(row.name.prefix(nameWidth - 1)) + "…"
                : row.name
            line += "  \(pad(trimmedName, nameWidth))"
        }
        if showFlagsCol {
            line += "  \(pad(row.flags, flagsWidth))"
        }
        let commandDisplay = full
            ? row.command
            : formatCommandPreview(row.command, maxWidth: commandBudget)
        line += "  \(commandDisplay)"
        print(line)
    }
}

func commandShow(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"], positionals: 1)
    if parsed.switches.contains("help") {
        printCommandHelp(["show"])
        return
    }
    guard let target = parsed.positionals.first else {
        throw CLIError(message: "show needs a keys binding or name", code: 2)
    }

    let config: Config
    do {
        config = try Config.load(from: Paths.config)
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }

    let index = try findUniqueShortcutIndex(in: config, target: target)
    let shortcut = config.shortcuts[index]
    let view = ShortcutView(shortcut)

    if wantsJSON(parsed) {
        try emitJSON("show", view)
        return
    }

    print("keys        \(view.keys)")
    if let name = view.name {
        print("name        \(name)")
    }
    print("enabled     \(view.enabled ? "yes" : "no")")
    print("mode        \(view.executionMode)" + (view.usesSelectedText ? " (uses SELECTED_TEXT)" : ""))
    var flags: [String] = []
    if view.passThrough { flags.append("passThrough") }
    if view.allowAccessibility { flags.append("allowAccessibility") }
    if !flags.isEmpty {
        print("flags       \(flags.joined(separator: ", "))")
    }
    if let dtDelay = view.maxDoubleTapDelayMs {
        print("doubleTapMs \(dtDelay)")
    }
    if let seqDelay = view.maxSequenceDelayMs {
        print("sequenceMs  \(seqDelay)")
    }
    if let timeout = view.timeoutMs {
        print("timeoutMs   \(timeout)")
    }
    if let cwd = view.cwd {
        print("cwd         \(cwd)")
    }
    if let tap = view.tap {
        print("")
        print("tap:")
        print(tap)
    }
    if let dt = view.doubleTap {
        print("")
        print("doubleTap:")
        print(dt)
    }
}

// MARK: - remove, enable, disable

struct RemovePayload: Encodable {
    let removed: String
    let slot: String?
    let dryRun: Bool
}

func commandRemove(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["json", "help", "tap", "double-tap", "dry-run"],
        positionals: 1
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["remove"])
        return
    }
    guard let target = parsed.positionals.first else {
        throw CLIError(message: "remove needs a keys binding or name", code: 2)
    }

    let onlyTap = parsed.switches.contains("tap")
    let onlyDoubleTap = parsed.switches.contains("double-tap")
    let dryRun = parsed.switches.contains("dry-run")
    if onlyTap && onlyDoubleTap {
        throw CLIError(
            message: "specify either --tap or --double-tap, or omit both to remove the entire shortcut",
            code: 2
        )
    }

    let (removedLabel, removedSlot) = try Config.withExclusiveLock(for: Paths.config) { () -> (String, String?) in
        var config: Config
        do {
            config = try loadConfigForEditing()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 7)
        }

        let index = try findUniqueShortcutIndex(in: config, target: target)
        var found = config.shortcuts[index]
        let label = found.displayName
        var slot: String?

        if onlyTap {
            guard found.tap != nil else {
                throw CLIError(message: "'\(label)' has no tap command to remove", code: 3)
            }
            slot = "tap"
            if found.doubleTap != nil {
                found.tap = nil
                config.shortcuts[index] = found
            } else {
                config.shortcuts.remove(at: index)
            }
        } else if onlyDoubleTap {
            guard found.doubleTap != nil else {
                throw CLIError(message: "'\(label)' has no doubleTap command to remove", code: 3)
            }
            slot = "doubleTap"
            if found.tap != nil {
                found.doubleTap = nil
                found.maxDoubleTapDelayMilliseconds = nil
                config.shortcuts[index] = found
            } else {
                config.shortcuts.remove(at: index)
            }
        } else {
            config.shortcuts.remove(at: index)
        }

        if !dryRun {
            do {
                try config.save(to: Paths.config)
            } catch {
                throw CLIError(message: error.localizedDescription, code: 7)
            }
        }
        return (label, slot)
    }
    if !dryRun {
        notifyDaemonToReload()
    }

    if wantsJSON(parsed) {
        try emitJSON("remove", RemovePayload(removed: removedLabel, slot: removedSlot, dryRun: dryRun))
    } else {
        let prefix = dryRun ? "[dry-run] would remove" : "removed"
        let slotSuffix = removedSlot.map { " (\($0))" } ?? ""
        print("\(prefix) \(removedLabel)\(slotSuffix)")
    }
}

func commandSetEnabled(_ arguments: [String], enabled: Bool) throws {
    let verb = enabled ? "enable" : "disable"
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["dry-run", "json", "help"],
        positionals: 1
    )
    if parsed.switches.contains("help") {
        printCommandHelp([verb])
        return
    }
    guard let target = parsed.positionals.first else {
        throw CLIError(message: "\(verb) needs a keys binding or name", code: 2)
    }
    let dryRun = parsed.switches.contains("dry-run")

    let (updated, warnings) = try Config.withExclusiveLock(for: Paths.config) { () -> (Shortcut, [String]) in
        var config: Config
        do {
            config = try loadConfigForEditing()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 7)
        }
        let index = try findUniqueShortcutIndex(in: config, target: target)
        config.shortcuts[index].enabled = enabled
        do {
            try config.validate()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 4)
        }
        let warnings = config.rolloverWarnings()
        if !dryRun {
            do {
                try config.save(to: Paths.config)
            } catch {
                throw CLIError(message: error.localizedDescription, code: 7)
            }
        }
        return (config.shortcuts[index], warnings)
    }
    if !dryRun {
        notifyDaemonToReload()
    }

    if wantsJSON(parsed) {
        if dryRun {
            try emitJSON(verb, DryRunMutationPayload(action: verb, shortcut: ShortcutView(updated), warnings: warnings))
        } else {
            try emitJSON(verb, ShortcutView(updated))
        }
        return
    }
    let prefix = dryRun ? "[dry-run] would \(verb)" : (enabled ? "enabled" : "disabled")
    print("\(prefix) \(updated.displayName) (\(updated.keys.canonical))")
}

// MARK: - validate & edit

struct ValidatePayload: Encodable {
    let valid: Bool
    let configPath: String
    let shortcuts: Int
    let enabled: Int
    let warnings: [String]
}

func commandValidate(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["validate"])
        return
    }

    let config: Config
    do {
        config = try Config.load(from: Paths.config)
    } catch let error as ConfigError {
        switch error {
        case .malformed:
            throw CLIError(message: error.localizedDescription, code: 4)
        default:
            throw CLIError(message: error.localizedDescription, code: 7)
        }
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }

    do {
        try config.validate()
    } catch {
        throw CLIError(message: error.localizedDescription, code: 4)
    }

    let warnings = config.rolloverWarnings()
    let payload = ValidatePayload(
        valid: true,
        configPath: Paths.config.path,
        shortcuts: config.shortcuts.count,
        enabled: config.shortcuts.filter(\.enabled).count,
        warnings: warnings
    )
    if wantsJSON(parsed) {
        try emitJSON("validate", payload)
        return
    }

    print("✓ config valid: \(payload.shortcuts) shortcut(s) (\(payload.enabled) enabled) at \(payload.configPath)")
    for warning in warnings {
        print("! warning: \(warning)")
    }
}

private func readVerifiedRawConfigBytes(from url: URL) throws -> Data {
    let filename = url.lastPathComponent
    let parentPath = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
    guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
        throw ConfigError.insecureConfig("invalid configuration path '\(url.path)'")
    }
    if !Paths.isEnvironmentOverrideActive {
        try StrictModes.verifySecurePath(parentPath, expectRegularFile: false)
    }
    let dirFD = try StrictModes.openVerifiedDirectory(parentPath)
    defer { close(dirFD) }

    let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else {
        let err = errno
        if err == ELOOP {
            throw ConfigError.insecureConfig("refusing to read symlinked configuration at '\(url.path)'")
        }
        throw ConfigError.insecureConfig("could not open '\(url.path)': \(String(cString: strerror(err)))")
    }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0,
          (st.st_mode & S_IFMT) == S_IFREG,
          st.st_uid == getuid(),
          (st.st_mode & 0o077) == 0,
          st.st_size >= 0,
          st.st_size <= off_t(Config.maxFileSizeBytes) else {
        throw ConfigError.insecureConfig("configuration at '\(url.path)' failed ownership, mode 0600, or size verification")
    }

    var data = Data()
    data.reserveCapacity(Int(st.st_size))
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let n = buffer.withUnsafeMutableBytes { raw -> ssize_t in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base, raw.count)
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw ConfigError.insecureConfig("read failed on '\(url.path)': \(String(cString: strerror(errno)))")
        }
        if n == 0 { break }
        data.append(buffer, count: n)
        if data.count > Config.maxFileSizeBytes {
            throw ConfigError.insecureConfig("configuration at '\(url.path)' exceeds maximum size of \(Config.maxFileSizeBytes) bytes")
        }
    }
    return data
}

func commandEdit(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["edit"])
        return
    }
    guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
        throw CLIError(
            message: "hotkeyd edit requires an interactive terminal (use `hotkeyd set` or `hotkeyd add` in scripts)",
            code: 2
        )
    }

    try Paths.ensureDirectories()
    let editorCandidates: [String?] = [
        getenv("VISUAL").map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) },
        getenv("EDITOR").map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) },
        "/usr/bin/vi"
    ]
    guard let editor = editorCandidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
        throw CLIError(message: "$VISUAL / $EDITOR is empty", code: 2)
    }
    guard !editor.contains("\0") && !editor.contains("\n") && !editor.contains("\r") else {
        throw CLIError(message: "invalid $VISUAL / $EDITOR value", code: 2)
    }

    let tempURL = Paths.root.appendingPathComponent(".edit-\(UUID().uuidString).hotkeyd")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let initialData: Data
    do {
        let existing = try Config.load(from: Paths.config)
        initialData = try existing.formattedJSON()
    } catch ConfigError.fileMissing {
        initialData = Data("{\n  \"shortcuts\": []\n}\n".utf8)
    } catch ConfigError.malformed {
        // Only allow editing raw bytes when the file is already StrictModes-verified (`0600`,
        // regular file, owned by uid, `<= 1 MiB`) and simply has a JSON syntax error to fix.
        do {
            initialData = try readVerifiedRawConfigBytes(from: Paths.config)
        } catch {
            throw CLIError(message: error.localizedDescription, code: 7)
        }
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }
    try StrictModes.atomicWrite(initialData, to: tempURL, mode: 0o600)

    // Enforce 0600 on atomic-saving editors and unconditionally disclaim TCC Accessibility
    // responsibility via `ShellRunner.spawnProcess` so `hotkeyd edit` can never act as a
    // Confused Deputy for `kTCCServiceAccessibility`.
    let previousUmask = umask(0o077)
    defer { _ = umask(previousUmask) }

    let callerEnv = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
    let spawnResult = ShellRunner.spawnProcess(
        executablePath: "/bin/zsh",
        arguments: ["/bin/zsh", "-fc", "exec \(editor) \"$1\"", "_", tempURL.path],
        environment: callerEnv,
        workingDirectory: Paths.realHomeDirectory.path,
        stdinFD: -1,
        stdoutFD: -1,
        stderrFD: -1,
        disclaimResponsibility: true,
        setProcessGroup: false,
        inheritStandardIO: true
    )

    let editorPID: pid_t
    switch spawnResult {
    case .success(let pid):
        editorPID = pid
    case .failure(let err):
        throw CLIError(
            message: "could not launch editor: \(String(cString: strerror(err.errnoCode)))",
            code: 8
        )
    }

    var rawStatus: Int32 = 0
    while true {
        let waited = waitpid(editorPID, &rawStatus, 0)
        if waited == editorPID { break }
        if waited < 0 && errno == EINTR { continue }
        break
    }
    let signalBits = rawStatus & 0x7f
    let exitStatus = signalBits == 0 ? ((rawStatus >> 8) & 0xff) : (128 + signalBits)
    guard exitStatus == 0 else {
        throw CLIError(
            message: "editor exited with status \(exitStatus); \(Paths.config.path) unchanged",
            code: 8
        )
    }

    let editedConfig: Config
    do {
        editedConfig = try Config.load(from: tempURL)
    } catch {
        throw CLIError(
            message: "edited config failed to parse (\(error.localizedDescription)); \(Paths.config.path) unchanged",
            code: 4
        )
    }
    do {
        try editedConfig.validate()
    } catch {
        throw CLIError(
            message: "edited config failed validation (\(error.localizedDescription)); \(Paths.config.path) unchanged",
            code: 4
        )
    }

    try Config.withExclusiveLock(for: Paths.config) {
        try editedConfig.save(to: Paths.config)
    }
    notifyDaemonToReload()
    print("saved \(editedConfig.shortcuts.count) shortcut(s) to \(Paths.config.path) (mode 0600)")
    for warning in editedConfig.rolloverWarnings() {
        print("! warning: \(warning)")
    }
}

// MARK: - run

struct RunPayload: Encodable {
    let name: String
    let command: String
    let detached: Bool
    let exitCode: Int32
    let timedOut: Bool
    let durationMilliseconds: Int
    let stdout: String
    let stderr: String
}

func commandRun(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["json", "wait", "help", "tap", "double-tap"],
        positionals: 1
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["run"])
        return
    }
    guard let target = parsed.positionals.first else {
        throw CLIError(message: "run needs a keys binding or name", code: 2)
    }
    let wantTap = parsed.switches.contains("tap")
    let wantDoubleTap = parsed.switches.contains("double-tap")
    if wantTap && wantDoubleTap {
        throw CLIError(message: "specify either --tap or --double-tap, not both", code: 2)
    }

    let config: Config
    do {
        config = try Config.load(from: Paths.config)
    } catch {
        throw CLIError(message: error.localizedDescription, code: 7)
    }

    let index = try findUniqueShortcutIndex(in: config, target: target)
    var shortcut = config.shortcuts[index]

    if wantDoubleTap {
        guard shortcut.doubleTap != nil else {
            throw CLIError(message: "'\(shortcut.displayName)' has no doubleTap command", code: 4)
        }
        shortcut.tap = nil
    } else if wantTap {
        guard shortcut.tap != nil else {
            throw CLIError(message: "'\(shortcut.displayName)' has no tap command", code: 4)
        }
        shortcut.doubleTap = nil
    }

    let actionLabel = shortcut.activeCommand
    guard parsed.switches.contains("wait") else {
        do {
            try ShellRunner.dispatchDetached(shortcut: shortcut)
        } catch {
            throw CLIError(message: "could not dispatch '\(shortcut.displayName)': \(error.localizedDescription)", code: 8)
        }
        if wantsJSON(parsed) {
            try emitJSON("run", RunPayload(
                name: shortcut.displayName,
                command: actionLabel,
                detached: true,
                exitCode: 0,
                timedOut: false,
                durationMilliseconds: 0,
                stdout: "",
                stderr: ""
            ))
        } else {
            print("dispatched \(shortcut.displayName)")
        }
        return
    }

    let result = ShellRunner.execute(
        action: shortcut.activeAction,
        allowAccessibility: shortcut.allowAccessibility
    )
    let succeeded = result.exitCode == 0 && !result.timedOut
    if wantsJSON(parsed) {
        try emitJSON("run", RunPayload(
            name: shortcut.displayName,
            command: actionLabel,
            detached: false,
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            durationMilliseconds: result.durationMilliseconds,
            stdout: result.stdout,
            stderr: result.stderr
        ), ok: succeeded)
    } else {
        print("\(shortcut.displayName) -> exit \(result.exitCode) in \(result.durationMilliseconds) ms")
        if !result.stdout.isEmpty { print(result.stdout, terminator: "") }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
    }
    if !succeeded {
        exit(8)
    }
}

// MARK: - migrate-actions

struct MigratedShortcut: Encodable {
    let name: String
    let from: String
    let to: Action
}

struct MigrateActionsPayload: Encodable {
    let dryRun: Bool
    let migrated: [MigratedShortcut]
    let unchanged: Int
}

func commandMigrateActions(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["dry-run", "keep-names", "strip-names", "json", "help"]
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["migrate-actions"])
        return
    }

    let dryRun = parsed.switches.contains("dry-run")
    let stripNames = parsed.switches.contains("strip-names")
    if stripNames && parsed.switches.contains("keep-names") {
        throw CLIError(message: "specify either --keep-names or --strip-names, not both", code: 2)
    }

    let (migrated, unchanged) = try Config.withExclusiveLock(for: Paths.config) { () -> ([MigratedShortcut], Int) in
        var config: Config
        do {
            config = try loadConfigForEditing()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 7)
        }

        if stripNames {
            for index in config.shortcuts.indices {
                config.shortcuts[index].name = nil
            }
        }

        var migratedItems: [MigratedShortcut] = []
        var unchangedCount = 0
        for shortcut in config.shortcuts {
            var matched = false
            for command in [shortcut.tap, shortcut.doubleTap].compactMap({ $0 }) {
                if !shortcut.allowAccessibility,
                   shortcut.cwd == nil,
                   let nativeAction = Action.migratedFromShellCommand(command) {
                    migratedItems.append(MigratedShortcut(
                        name: shortcut.displayName,
                        from: command,
                        to: nativeAction
                    ))
                    matched = true
                }
            }
            if !matched {
                unchangedCount += 1
            }
        }

        if !dryRun {
            do {
                try config.validate()
                try config.save(to: Paths.config)
            } catch {
                throw CLIError(message: error.localizedDescription, code: 7)
            }
        }
        return (migratedItems, unchangedCount)
    }
    if !dryRun {
        notifyDaemonToReload()
    }

    let payload = MigrateActionsPayload(
        dryRun: dryRun,
        migrated: migrated,
        unchanged: unchanged
    )
    if wantsJSON(parsed) {
        try emitJSON("migrate-actions", payload)
        return
    }

    let prefix = dryRun ? "[dry-run] would format config &" : "formatted config &"
    print("\(prefix) verified \(migrated.count) native NSWorkspace command(s) (\(unchanged) shell shortcut(s)):")
    for item in migrated {
        print("  \(item.name): '\(item.from)' -> \(item.to.summary)")
    }
}

// MARK: - daemon

struct DaemonActionPayload: Encodable {
    let label: String
    let action: String
    let pid: Int?
    let binary: String?
    let plistPath: String?
    let alreadyRunning: Bool?
}

func commandDaemon(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
        if let groupHelp = CommandRegistry.formatGroupHelp(group: "daemon") {
            print(groupHelp)
        }
        throw CLIError(
            message: "daemon needs a subcommand (status, start, stop, reload, restart, logs, install, uninstall, run)",
            code: 2
        )
    }
    let rest = Array(arguments.dropFirst())
    if subcommand == "--help" || subcommand == "-h" || subcommand == "help" {
        if let target = rest.first, !target.hasPrefix("-"),
           let spec = CommandRegistry.findCommand(matching: ["daemon", target]) {
            print(CommandRegistry.formatHelp(for: spec))
        } else if let groupHelp = CommandRegistry.formatGroupHelp(group: "daemon") {
            print(groupHelp)
        }
        return
    }

    switch subcommand {
    case "status":
        try commandStatus(rest, helpPath: ["daemon", "status"], commandName: "daemon.status")

    case "logs":
        try commandLogs(rest, helpPath: ["daemon", "logs"])

    case "start":
        let parsed = try parseArguments(rest, valued: [], switches: ["json", "help"])
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "start"])
            return
        }
        guard !Paths.isEnvironmentOverrideActive else {
            throw CLIError(message: LaunchAgentError.environmentOverrideDisallowed.localizedDescription, code: 6)
        }
        do {
            if LaunchAgent.isLoaded(), let runningPID = LaunchAgent.pid() {
                let payload = DaemonActionPayload(
                    label: LaunchAgent.label,
                    action: "start",
                    pid: runningPID,
                    binary: LaunchAgent.installedBinaryPath(),
                    plistPath: LaunchAgent.plistPath,
                    alreadyRunning: true
                )
                if wantsJSON(parsed) {
                    try emitJSON("daemon.start", payload)
                } else {
                    print("daemon already running (pid \(runningPID))")
                }
                return
            }
            if LaunchAgent.isLoaded() {
                try LaunchAgent.restart()
            } else {
                let binary = LaunchAgent.installedBinaryPath() ?? rawExecutablePath()
                try LaunchAgent.install(
                    binaryPath: binary,
                    allowAdhoc: LaunchAgent.installedAllowsAdhoc()
                )
            }
            let pid = LaunchAgent.pid()
            let payload = DaemonActionPayload(
                label: LaunchAgent.label,
                action: "start",
                pid: pid,
                binary: LaunchAgent.installedBinaryPath(),
                plistPath: LaunchAgent.plistPath,
                alreadyRunning: false
            )
            if wantsJSON(parsed) {
                try emitJSON("daemon.start", payload)
            } else {
                print("daemon started (\(LaunchAgent.label))" + (pid.map { " pid=\($0)" } ?? ""))
            }
        } catch {
            throw CLIError(message: error.localizedDescription, code: 6)
        }

    case "stop":
        let parsed = try parseArguments(rest, valued: [], switches: ["json", "help"])
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "stop"])
            return
        }
        guard !Paths.isEnvironmentOverrideActive else {
            throw CLIError(message: LaunchAgentError.environmentOverrideDisallowed.localizedDescription, code: 6)
        }
        let bootout = tool("/bin/launchctl", ["bootout", "\(LaunchAgent.domain)/\(LaunchAgent.label)"])
        var capsRestored = true
        if case .enabled = CapsLock.state() {
            do {
                try CapsLock.disable()
            } catch {
                capsRestored = false
            }
        }
        let stateOff = CapsLock.ensureCapsLockOff()
        RuntimeState.remove(at: Paths.runtimeState)
        let payload = PanicPayload(
            daemonStopped: bootout.status == 0 || !LaunchAgent.isLoaded(),
            capsLockRestored: capsRestored,
            capsLockStateOff: stateOff
        )
        if wantsJSON(parsed) {
            try emitJSON("daemon.stop", payload)
            return
        }
        print("daemon stopped")

    case "reload":
        let parsed = try parseArguments(rest, valued: [], switches: ["json", "help"])
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "reload"])
            return
        }
        do {
            let pid = try LaunchAgent.reload()
            let payload = DaemonActionPayload(
                label: LaunchAgent.label,
                action: "reload",
                pid: pid,
                binary: LaunchAgent.installedBinaryPath(),
                plistPath: LaunchAgent.plistPath,
                alreadyRunning: nil
            )
            if wantsJSON(parsed) {
                try emitJSON("daemon.reload", payload)
            } else {
                print("reloaded daemon (sent SIGHUP to pid \(pid))")
            }
        } catch {
            throw CLIError(message: error.localizedDescription, code: 6)
        }

    case "run":
        let parsed = try parseArguments(rest, valued: [], switches: ["help", "allow-adhoc"])
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "run"])
            return
        }
        // Ignore inherited HOTKEYD_HOME inside the TCC-trusted daemon; the daemon exclusively
        // reads the verified ~/.hotkeyd path so sandboxed callers cannot redirect it.
        Paths.ignoreEnvironmentOverride = true
        unsetenv("HOTKEYD_HOME")
        let daemon = Daemon(
            configURL: Paths.config,
            binaryPath: rawExecutablePath(),
            allowAdhoc: parsed.switches.contains("allow-adhoc")
        )
        daemon.start()
        withExtendedLifetime(daemon) {
            dispatchMain()
        }

    case "install":
        let parsed = try parseArguments(
            rest,
            valued: ["binary"],
            switches: ["no-open", "json", "help", "allow-adhoc"]
        )
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "install"])
            return
        }
        let binary = parsed.values["binary"] ?? rawExecutablePath()
        guard FileManager.default.fileExists(atPath: binary) else {
            throw CLIError(message: "binary not found at \(binary)", code: 2)
        }
        let openSettings = !parsed.switches.contains("no-open") && !wantsJSON(parsed)
        do {
            try LaunchAgent.install(
                binaryPath: binary,
                allowAdhoc: parsed.switches.contains("allow-adhoc"),
                suppressAXPrompt: true
            )
        } catch {
            throw CLIError(message: error.localizedDescription, code: 6)
        }
        if openSettings {
            _ = tool("/usr/bin/open", [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ])
        }
        if wantsJSON(parsed) {
            try emitJSON("daemon.install", DaemonActionPayload(
                label: LaunchAgent.label,
                action: "install",
                pid: LaunchAgent.pid(),
                binary: binary,
                plistPath: LaunchAgent.plistPath,
                alreadyRunning: nil
            ))
            return
        }
        print("installed launch agent: \(LaunchAgent.plistPath)")
        print("daemon binary:         \(binary)")
        print("")
        print("If shortcuts do not fire yet, grant Accessibility:")
        print("  System Settings > Privacy & Security > Accessibility > enable \"hotkeyd\"")
        print("  hotkeyd doctor")

    case "uninstall":
        let parsed = try parseArguments(rest, valued: [], switches: ["json", "help"])
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "uninstall"])
            return
        }
        do {
            try LaunchAgent.uninstall()
            RuntimeState.remove(at: Paths.runtimeState)
        } catch {
            throw CLIError(message: error.localizedDescription, code: 6)
        }
        if wantsJSON(parsed) {
            try emitJSON("daemon.uninstall", DaemonActionPayload(
                label: LaunchAgent.label,
                action: "uninstall",
                pid: nil,
                binary: nil,
                plistPath: LaunchAgent.plistPath,
                alreadyRunning: nil
            ))
            return
        }
        print("removed launch agent")
        print("the Accessibility entry for hotkeyd is managed by macOS and must be removed by hand")

    case "restart":
        let parsed = try parseArguments(rest, valued: [], switches: ["json", "help"])
        if parsed.switches.contains("help") {
            printCommandHelp(["daemon", "restart"])
            return
        }
        do {
            try LaunchAgent.restart()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 6)
        }
        let pid = LaunchAgent.pid()
        if wantsJSON(parsed) {
            try emitJSON("daemon.restart", DaemonActionPayload(
                label: LaunchAgent.label,
                action: "restart",
                pid: pid,
                binary: LaunchAgent.installedBinaryPath(),
                plistPath: LaunchAgent.plistPath,
                alreadyRunning: nil
            ))
            return
        }
        print("daemon restarted" + (pid.map { " (pid \($0))" } ?? ""))

    default:
        throw CLIError(message: "unknown daemon command '\(subcommand)'", code: 2)
    }
}

// MARK: - panic

struct PanicPayload: Encodable {
    let daemonStopped: Bool
    let capsLockRestored: Bool
    let capsLockStateOff: Bool
}

func commandPanic(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["panic"])
        return
    }
    guard !Paths.isEnvironmentOverrideActive else {
        throw CLIError(message: LaunchAgentError.environmentOverrideDisallowed.localizedDescription, code: 6)
    }

    let bootout = tool("/bin/launchctl", ["bootout", "\(LaunchAgent.domain)/\(LaunchAgent.label)"])
    var capsRestored = true
    if case .enabled = CapsLock.state() {
        do {
            try CapsLock.disable()
        } catch {
            capsRestored = false
        }
    }
    let stateOff = CapsLock.ensureCapsLockOff()
    RuntimeState.remove(at: Paths.runtimeState)
    let payload = PanicPayload(
        daemonStopped: bootout.status == 0 || !LaunchAgent.isLoaded(),
        capsLockRestored: capsRestored,
        capsLockStateOff: stateOff
    )

    if wantsJSON(parsed) {
        try emitJSON("panic", payload)
        return
    }
    print("panic recovery complete:")
    print("  daemon stopped:     \(payload.daemonStopped ? "yes" : "no")")
    print("  caps remap cleared: \(payload.capsLockRestored ? "yes" : "no")")
    print("  caps state off:     \(payload.capsLockStateOff ? "yes" : "no")")
}

// MARK: - caps

struct CapsPayload: Encodable {
    /// Remap state: off, enabled or foreign.
    let remap: String
    /// Actual Caps Lock state, independent of the remap.
    let capsState: String
    let detail: String?
}

private func describeCapsState(_ state: CapsLock.State) -> CapsPayload {
    let capsOn = CapsLock.isCapsLockOn()
    switch state {
    case .off:
        return CapsPayload(
            remap: "off",
            capsState: capsOn ? "on" : "off",
            detail: "Caps Lock behaves normally"
        )
    case .enabled:
        return CapsPayload(
            remap: "enabled",
            capsState: capsOn ? "on" : "off",
            detail: capsOn
                ? "Caps Lock is remapped to F18 and the state is ON; run `hotkeyd caps reset`"
                : "Caps Lock is remapped to F18"
        )
    case .foreign(let detail):
        return CapsPayload(remap: "foreign", capsState: capsOn ? "on" : "off", detail: detail)
    }
}

func commandCaps(_ arguments: [String]) throws {
    let subcommand: String
    let rest: [String]
    if let first = arguments.first {
        if first == "--help" || first == "-h" || first == "help" {
            let after = Array(arguments.dropFirst())
            if let target = after.first, !target.hasPrefix("-"),
               let spec = CommandRegistry.findCommand(matching: ["caps", target]) {
                print(CommandRegistry.formatHelp(for: spec))
            } else if let groupHelp = CommandRegistry.formatGroupHelp(group: "caps") {
                print(groupHelp)
            }
            return
        }
        if first.hasPrefix("-") {
            // `hotkeyd caps --json` defaults to `caps status --json`.
            subcommand = "status"
            rest = arguments
        } else {
            subcommand = first
            rest = Array(arguments.dropFirst())
        }
    } else {
        subcommand = "status"
        rest = []
    }

    let parsed = try parseArguments(rest, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["caps", subcommand])
        return
    }

    switch subcommand {
    case "status":
        let payload = describeCapsState(CapsLock.state())
        if wantsJSON(parsed) {
            try emitJSON("caps.status", payload)
        } else {
            print("caps lock   remap=\(payload.remap) state=\(payload.capsState)")
            if let detail = payload.detail {
                print("            \(detail)")
            }
        }

    case "on":
        do {
            try CapsLock.enable()
        } catch let error as CapsLock.CapsError {
            let code: Int32
            if case .foreignMapping = error { code = 4 } else { code = 8 }
            throw CLIError(message: error.localizedDescription, code: code)
        } catch {
            throw CLIError(message: error.localizedDescription, code: 8)
        }
        let payload = describeCapsState(CapsLock.state())
        if wantsJSON(parsed) {
            try emitJSON("caps.on", payload)
        } else {
            print("caps lock remapped to F18")
            print("bind it with: hotkeyd add capsLock '<command>'")
        }

    case "reset":
        let wasOn = CapsLock.isCapsLockOn()
        let cleared = CapsLock.ensureCapsLockOff()
        if !cleared {
            throw CLIError(
                message: "Caps Lock is on and could not be cleared; press Caps Lock or use the on-screen keyboard",
                code: 8
            )
        }
        if wantsJSON(parsed) {
            try emitJSON("caps.reset", CapsPayload(
                remap: describeCapsState(CapsLock.state()).remap,
                capsState: CapsLock.isCapsLockOn() ? "on" : "off",
                detail: wasOn ? "was on, now off" : "already off"
            ))
        } else {
            print(wasOn ? "caps lock turned off" : "caps lock was already off")
        }

    case "off":
        do {
            try CapsLock.disable()
        } catch {
            throw CLIError(message: error.localizedDescription, code: 8)
        }
        if wantsJSON(parsed) {
            try emitJSON("caps.off", describeCapsState(CapsLock.state()))
        } else {
            print("caps lock restored")
        }

    default:
        throw CLIError(message: "unknown caps command '\(subcommand)'", code: 2)
    }
}

// MARK: - status & logs

struct StatusPayload: Encodable {
    let configPath: String
    let configExists: Bool
    let configValid: Bool
    let configError: String?
    let shortcuts: Int
    let enabled: Int
    let sandboxed: Bool
    let daemonLoaded: Bool
    let daemonPID: Int?
    let tapInstalled: Bool
    let tapNote: String?
    let secureInputActive: Bool
    let paused: Bool
    let pausedUntil: String?
    let pauseReason: String?
    let peekEnabled: Bool
    let binary: String
    let recentActions: [String]
}

func gatherStatus() -> StatusPayload {
    var config = Config()
    var exists = true
    var valid = true
    var configErrorText: String?
    do {
        config = try Config.load(from: Paths.config)
        try config.validate()
    } catch ConfigError.fileMissing {
        exists = false
        valid = false
        configErrorText = nil
    } catch {
        valid = false
        configErrorText = error.localizedDescription
    }

    let sandboxed = Paths.isEnvironmentOverrideActive
    let loaded: Bool
    let pid: Int?
    if sandboxed {
        loaded = false
        if let state = RuntimeState.load(from: Paths.runtimeState),
           state.pid > 1,
           kill(state.pid, 0) == 0 {
            pid = Int(state.pid)
        } else {
            pid = nil
        }
    } else {
        loaded = LaunchAgent.isLoaded()
        pid = LaunchAgent.pid()
    }

    let tap = tapState(daemonPID: pid, sandboxed: sandboxed)
    let activePause = PauseState.loadActive(from: Paths.pauseState, pruneExpired: false)
    let liveState = pid.flatMap { runningPID -> RuntimeState? in
        guard let st = RuntimeState.load(from: Paths.runtimeState), Int(st.pid) == runningPID else {
            return nil
        }
        return st
    }
    let isPaused = activePause != nil || (liveState?.paused ?? false)
    let pausedUntil = activePause?.resumeAt ?? liveState?.pausedUntil
    let pauseReason = activePause?.reason ?? liveState?.pauseReason

    return StatusPayload(
        configPath: Paths.config.path,
        configExists: exists,
        configValid: valid,
        configError: configErrorText,
        shortcuts: config.shortcuts.count,
        enabled: config.shortcuts.filter(\.enabled).count,
        sandboxed: sandboxed,
        daemonLoaded: loaded,
        daemonPID: pid,
        tapInstalled: tap.installed,
        tapNote: tap.note,
        secureInputActive: tap.secureInputActive,
        paused: isPaused,
        pausedUntil: pausedUntil,
        pauseReason: pauseReason,
        peekEnabled: liveState?.peekEnabled ?? config.peek.enabled,
        binary: sandboxed ? executablePath() : (LaunchAgent.installedBinaryPath() ?? executablePath()),
        recentActions: Array(tail(Paths.actionLog, lines: 5))
    )
}

func commandStatus(
    _ arguments: [String],
    helpPath: [String] = ["status"],
    commandName: String = "status"
) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(helpPath)
        return
    }
    let status = gatherStatus()
    if wantsJSON(parsed) {
        try emitJSON(commandName, status)
        return
    }

    print("config      \(status.configPath)")
    if !status.configExists {
        print("shortcuts   not created yet")
    } else {
        print("shortcuts   \(status.shortcuts) total, \(status.enabled) enabled" + (status.configValid ? "" : "  [invalid]"))
    }
    if let error = status.configError {
        print("            \(error)")
    }
    if status.sandboxed {
        print("daemon      sandboxed (HOTKEYD_HOME active; LaunchAgent bypassed)")
    } else if status.daemonLoaded {
        if let pid = status.daemonPID {
            print("daemon      running (pid \(pid))")
        } else {
            print("daemon      loaded (not running)")
        }
    } else {
        print("daemon      not installed")
    }
    print("event tap   " + (status.tapInstalled ? "active" : "inactive") + (status.secureInputActive ? " [paused: Secure Event Input]" : ""))
    if status.paused {
        let activePause = PauseState.loadActive(from: Paths.pauseState)
        let timing = activePause?.formattedRemaining().map { "auto-resumes in \($0)" } ?? "indefinite; run `hotkeyd resume`"
        let reasonSuffix = status.pauseReason.map { " — reason: \($0)" } ?? ""
        print("state       paused (\(timing))\(reasonSuffix)")
    }
    if let note = status.tapNote {
        print("            \(note)")
    }
    if !status.recentActions.isEmpty {
        print("recent actions")
        status.recentActions.forEach { print("  \(formatLogLineForTerminal($0, utc: false))") }
    }
}

struct LogsPayload: Encodable {
    let daemonLogPath: String
    let actionLogPath: String
    let lines: Int
    let daemon: [String]
    let actions: [String]
}

private let isoParserWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoParserPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let localLogDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func formatLogLineForTerminal(_ line: String, utc: Bool) -> String {
    guard !utc else { return line }
    guard let spaceIdx = line.firstIndex(of: " ") else { return line }
    let prefix = String(line[..<spaceIdx])
    guard prefix.hasSuffix("Z"),
          let date = isoParserWithFraction.date(from: prefix) ?? isoParserPlain.date(from: prefix) else {
        return line
    }
    return localLogDateFormatter.string(from: date) + String(line[spaceIdx...])
}

func commandLogs(_ arguments: [String], helpPath: [String] = ["logs"]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: ["lines"],
        switches: ["daemon", "actions", "follow", "utc", "json", "help"]
    )
    if parsed.switches.contains("help") {
        printCommandHelp(helpPath)
        return
    }

    var lineCount = 50
    if let rawLines = parsed.values["lines"] {
        guard let value = Int(rawLines), value > 0, value <= 10_000 else {
            throw CLIError(message: "--lines must be an integer between 1 and 10000", code: 2)
        }
        lineCount = value
    }

    let wantDaemonOnly = parsed.switches.contains("daemon")
    let wantActionsOnly = parsed.switches.contains("actions")
    let includeDaemon = wantDaemonOnly || !wantActionsOnly
    let includeActions = wantActionsOnly || !wantDaemonOnly
    let follow = parsed.switches.contains("follow")
    let utc = parsed.switches.contains("utc")

    if follow && wantsJSON(parsed) {
        throw CLIError(message: "--follow cannot be combined with --json", code: 2)
    }

    let daemonLines = includeDaemon ? tail(Paths.daemonLog, lines: lineCount) : []
    let actionLines = includeActions ? tail(Paths.actionLog, lines: lineCount) : []

    if wantsJSON(parsed) {
        try emitJSON(
            helpPath.joined(separator: "."),
            LogsPayload(
                daemonLogPath: Paths.daemonLog.path,
                actionLogPath: Paths.actionLog.path,
                lines: lineCount,
                daemon: daemonLines,
                actions: actionLines
            )
        )
        return
    }

    if includeDaemon {
        print("==> \(Paths.daemonLog.path) <==")
        if daemonLines.isEmpty {
            print("  (empty)")
        } else {
            daemonLines.forEach { print(formatLogLineForTerminal($0, utc: utc)) }
        }
    }
    if includeDaemon && includeActions {
        print("")
    }
    if includeActions {
        print("==> \(Paths.actionLog.path) <==")
        if actionLines.isEmpty {
            print("  (empty)")
        } else {
            actionLines.forEach { print(formatLogLineForTerminal($0, utc: utc)) }
        }
    }

    guard follow else { return }

    // Follow newly appended lines across rotations until SIGINT/SIGTERM.
    struct TrackedFile {
        let label: String
        let url: URL
        var inode: UInt64
        var offset: UInt64
        var remainder: String
    }

    func initialTrack(label: String, url: URL) -> TrackedFile {
        var st = stat()
        if stat(url.path, &st) == 0 {
            return TrackedFile(label: label, url: url, inode: st.st_ino, offset: UInt64(max(0, st.st_size)), remainder: "")
        }
        return TrackedFile(label: label, url: url, inode: 0, offset: 0, remainder: "")
    }

    var tracked: [TrackedFile] = []
    if includeDaemon { tracked.append(initialTrack(label: "daemon", url: Paths.daemonLog)) }
    if includeActions { tracked.append(initialTrack(label: "action", url: Paths.actionLog)) }

    let showLabel = tracked.count > 1
    fflush(stdout)
    while true {
        usleep(200_000)
        for i in tracked.indices {
            var st = stat()
            guard stat(tracked[i].url.path, &st) == 0 else { continue }
            let size = UInt64(max(0, st.st_size))
            if st.st_ino != tracked[i].inode || size < tracked[i].offset {
                tracked[i].inode = st.st_ino
                tracked[i].offset = 0
                tracked[i].remainder = ""
            }
            guard size > tracked[i].offset,
                  let handle = try? FileHandle(forReadingFrom: tracked[i].url) else {
                continue
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: tracked[i].offset)
            guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { continue }
            tracked[i].offset += UInt64(chunk.count)
            let combined = tracked[i].remainder + String(decoding: chunk, as: UTF8.self)
            var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            tracked[i].remainder = combined.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
            for rawLine in lines where !rawLine.isEmpty {
                let formatted = formatLogLineForTerminal(rawLine, utc: utc)
                if showLabel {
                    print("[\(tracked[i].label)] \(formatted)")
                } else {
                    print(formatted)
                }
            }
            fflush(stdout)
        }
    }
}

// MARK: - doctor

struct DoctorCheck: Encodable {
    let id: String
    let ok: Bool
    let detail: String
    let fix: String?
}

struct DoctorPayload: Encodable {
    let ok: Bool
    let checks: [DoctorCheck]
}

func commandDoctor(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["doctor"])
        return
    }

    var checks: [DoctorCheck] = []
    let sandboxed = Paths.isEnvironmentOverrideActive
    let binary = sandboxed ? executablePath() : (LaunchAgent.installedBinaryPath() ?? executablePath())
    var capsLockBound = false
    var privilegedShortcutsCount = 0
    var migratableShellCount = 0

    // configuration
    do {
        let config = try Config.load(from: Paths.config)
        try config.validate()
        capsLockBound = config.requiresCapsLockRemap
        privilegedShortcutsCount = config.shortcuts.filter {
            $0.enabled && $0.allowAccessibility
        }.count
        migratableShellCount = config.shortcuts.reduce(into: 0) { count, shortcut in
            guard shortcut.enabled, !shortcut.allowAccessibility, shortcut.cwd == nil else {
                return
            }
            for command in [shortcut.tap, shortcut.doubleTap].compactMap({ $0 }) {
                if Action.migratedFromShellCommand(command) != nil {
                    count += 1
                }
            }
        }
        let rolloverCount = config.rolloverWarnings().count
        var detail = "\(config.shortcuts.count) shortcut(s) at \(Paths.config.path)"
        if rolloverCount > 0 {
            detail += " (\(rolloverCount) rollover warning(s); run `hotkeyd validate`)"
        }
        checks.append(DoctorCheck(
            id: "config",
            ok: true,
            detail: detail,
            fix: nil
        ))
    } catch ConfigError.fileMissing {
        checks.append(DoctorCheck(
            id: "config",
            ok: false,
            detail: "no configuration yet",
            fix: "hotkeyd init  (or `hotkeyd add lcmd 'open -a Terminal'`)"
        ))
    } catch {
        checks.append(DoctorCheck(
            id: "config",
            ok: false,
            detail: error.localizedDescription,
            fix: "fix \(Paths.config.path) or run `hotkeyd edit`"
        ))
    }

    // TCC responsibility isolation for child shells
    let tccDisclaimReady = ShellRunner.responsiblePID(for: getpid()) > 0
    var tccDetail = privilegedShortcutsCount == 0
        ? "shell children disclaim Accessibility (0 shortcuts opt in)"
        : "shell children disclaim Accessibility by default (\(privilegedShortcutsCount) shortcut(s) opt in via --allow-accessibility)"
    if migratableShellCount > 0 {
        tccDetail += "; \(migratableShellCount) open command(s) use native NSWorkspace fast-path"
    }
    checks.append(DoctorCheck(
        id: "tcc_delegation",
        ok: tccDisclaimReady,
        detail: tccDetail,
        fix: tccDisclaimReady ? nil : "verify macOS libSystem responsibility APIs"
    ))

    var pid: Int?
    var tap = (installed: false, note: Optional<String>.none, secureInputActive: false)

    if sandboxed {
        checks.append(DoctorCheck(
            id: "launch_agent",
            ok: true,
            detail: "skipped (HOTKEYD_HOME sandbox active)",
            fix: nil
        ))
        checks.append(DoctorCheck(
            id: "daemon",
            ok: true,
            detail: "skipped (HOTKEYD_HOME sandbox active)",
            fix: nil
        ))
        tap = (true, "skipped (HOTKEYD_HOME sandbox active)", false)
        checks.append(DoctorCheck(
            id: "event_tap",
            ok: true,
            detail: "skipped (HOTKEYD_HOME sandbox active)",
            fix: nil
        ))
    } else {
        // launch agent & plist StrictModes/0600 audit
        let loaded = LaunchAgent.isLoaded()
        let plistCheck = LaunchAgent.inspectInstalledPlist()
        switch plistCheck {
        case .insecure(let reason):
            checks.append(DoctorCheck(
                id: "launch_agent",
                ok: false,
                detail: reason,
                fix: "hotkeyd daemon install"
            ))
        case .valid, .missing:
            checks.append(DoctorCheck(
                id: "launch_agent",
                ok: loaded,
                detail: loaded ? "loaded (\(LaunchAgent.label))" : "not loaded",
                fix: loaded ? nil : "hotkeyd daemon install"
            ))
        }

        // process
        pid = LaunchAgent.pid()
        checks.append(DoctorCheck(
            id: "daemon",
            ok: pid != nil,
            detail: pid.map { "running (pid \($0))" } ?? "not running",
            fix: pid == nil ? "hotkeyd daemon start  (or `hotkeyd daemon install`)" : nil
        ))

        // tap / permission
        tap = tapState(daemonPID: pid, sandboxed: false)
        let activePause = PauseState.loadActive(from: Paths.pauseState)
        let tapDetail: String
        if tap.installed {
            if let activePause {
                let remaining = activePause.formattedRemaining().map { " for \($0)" } ?? ""
                tapDetail = "active (paused via `hotkeyd pause`\(remaining); run `hotkeyd resume`)"
            } else if tap.secureInputActive {
                tapDetail = "active (currently paused while Secure Event Input is active)"
            } else {
                tapDetail = "active; modifiers and keys are visible"
            }
        } else {
            tapDetail = tap.note ?? "inactive"
        }
        checks.append(DoctorCheck(
            id: "event_tap",
            ok: tap.installed,
            detail: tapDetail,
            fix: tap.installed
                ? nil
                : "enable \"hotkeyd\" in System Settings > Privacy & Security > Accessibility (activates automatically, or run `hotkeyd init`)"
        ))
    }

    // caps lock remap, only relevant when a capsLock gesture is bound or remap is currently active
    if !sandboxed {
        let capsState = CapsLock.state()
        if case .enabled = capsState {
            let capsOn = CapsLock.isCapsLockOn()
            checks.append(DoctorCheck(
                id: "caps_lock",
                ok: !capsOn,
                detail: capsOn
                    ? "remapped to F18, but the Caps Lock state is ON and the key cannot clear it"
                    : "remapped to F18" + (capsLockBound ? "; capsLock binding is live" : " (no shortcut uses it; run `hotkeyd caps off` to restore)"),
                fix: capsOn ? "hotkeyd caps reset" : nil
            ))
        } else if case .foreign(let detail) = capsState {
            checks.append(DoctorCheck(
                id: "caps_lock",
                ok: false,
                detail: "another mapping is active: \(detail)",
                fix: "hotkeyd will not overwrite it; clear it in the other tool first"
            ))
        } else if capsLockBound {
            if PauseState.loadActive(from: Paths.pauseState) != nil {
                checks.append(DoctorCheck(
                    id: "caps_lock",
                    ok: true,
                    detail: "temporarily restored while paused (will re-enable on `hotkeyd resume`)",
                    fix: nil
                ))
            } else {
                checks.append(DoctorCheck(
                    id: "caps_lock",
                    ok: false,
                    detail: "not remapped; capsLock binding cannot fire",
                    fix: "hotkeyd daemon restart  (or `hotkeyd caps on`)"
                ))
            }
        }
    }

    // signing identity & Hardened Runtime
    let installedAllowsAdhoc = !sandboxed && LaunchAgent.installedAllowsAdhoc()
    do {
        let binaryReport = try CodeTrust.verify(binaryPath: binary, allowAdhoc: false)
        var liveRuntimeOK = true
        var liveError: String?
        if let pid {
            do {
                let liveReport = try CodeTrust.verifyRunningProcess(
                    pid: pid_t(pid),
                    expectedBinaryPath: binary,
                    allowAdhoc: false
                )
                liveRuntimeOK = liveReport.hasHardenedRuntime && !liveReport.isAdhoc
            } catch {
                liveRuntimeOK = false
                liveError = error.localizedDescription
            }
        }
        let ok = binaryReport.hasHardenedRuntime && binaryReport.isLeafAnchored && liveRuntimeOK
        let detail = ok
            ? "certificate-anchored designated requirement + Hardened Runtime (CS_RUNTIME)"
            : (liveError ?? "running daemon signature does not match verified binary on disk")
        checks.append(DoctorCheck(
            id: "signing",
            ok: ok,
            detail: detail,
            fix: ok ? nil : "run setup-signing.sh and build.sh from the hotkeyd repository"
        ))
    } catch let strictError {
        if installedAllowsAdhoc {
            do {
                let adhocBinary = try CodeTrust.verify(binaryPath: binary, allowAdhoc: true)
                var liveOK = true
                var liveError: String?
                if let pid {
                    do {
                        let liveReport = try CodeTrust.verifyRunningProcess(
                            pid: pid_t(pid),
                            expectedBinaryPath: binary,
                            allowAdhoc: true
                        )
                        liveOK = liveReport.hasHardenedRuntime
                    } catch {
                        liveOK = false
                        liveError = error.localizedDescription
                    }
                }
                let ok = adhocBinary.hasHardenedRuntime && liveOK
                checks.append(DoctorCheck(
                    id: "signing",
                    ok: ok,
                    detail: ok
                        ? "ad-hoc mode (--allow-adhoc) + Hardened Runtime (CS_RUNTIME); SELECTED_TEXT and Accessibility delegation disabled"
                        : (liveError ?? "running daemon failed ad-hoc CodeTrust verification"),
                    fix: ok ? nil : "run setup-signing.sh and build.sh from the hotkeyd repository"
                ))
            } catch {
                checks.append(DoctorCheck(
                    id: "signing",
                    ok: false,
                    detail: error.localizedDescription,
                    fix: "run setup-signing.sh and build.sh from the hotkeyd repository"
                ))
            }
        } else {
            checks.append(DoctorCheck(
                id: "signing",
                ok: false,
                detail: strictError.localizedDescription,
                fix: "run setup-signing.sh and build.sh from the hotkeyd repository"
            ))
        }
    }

    let allOK = checks.allSatisfy(\.ok)
    if wantsJSON(parsed) {
        try emitJSON("doctor", DoctorPayload(ok: allOK, checks: checks), ok: allOK)
    } else {
        for check in checks {
            print("\(check.ok ? "✓" : "✗") \(pad(check.id, 15)) \(check.detail)")
            if let fix = check.fix {
                print("                  fix: \(fix)")
            }
        }
    }

    guard !allOK else { return }

    // Deterministic non-zero exit code for every failing check category.
    if checks.first(where: { $0.id == "daemon" || $0.id == "launch_agent" })?.ok == false {
        exit(6)
    }
    if checks.first(where: { $0.id == "event_tap" || $0.id == "tcc_delegation" })?.ok == false {
        exit(5)
    }
    if checks.first(where: { $0.id == "config" || $0.id == "signing" })?.ok == false {
        exit(7)
    }
    exit(4)
}

// MARK: - describe & schema

func commandDescribe(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["describe"])
        return
    }

    let manifest = CommandRegistry.manifest(
        version: version,
        configPath: Paths.config.path,
        logsPath: Paths.logs.path,
        launchAgentPath: LaunchAgent.plistPath
    )

    if wantsJSON(parsed) || isatty(STDOUT_FILENO) == 0 {
        try emitJSON("describe", manifest)
        return
    }

    print("\(manifest.name) \(manifest.version) — \(manifest.summary)")
    print("")
    print("COMMANDS (\(manifest.commands.count))")
    let nameWidth = max(18, manifest.commands.map { $0.displayName.count }.max() ?? 18)
    for cmd in manifest.commands {
        print("  \(pad(cmd.displayName, nameWidth))  \(cmd.summary)")
    }
    print("")
    print("pass `--json` for the complete machine-readable manifest.")
}

func commandSchema(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["json", "help"],
        positionals: 1
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["schema"])
        return
    }

    let target = parsed.positionals.first ?? "config"
    guard let rawSchemaData = CommandRegistry.renderJSONSchema(target: target) else {
        throw CLIError(
            message: "unknown schema target '\(target)'; expected 'config' or 'shortcut'",
            code: 2
        )
    }

    if wantsJSON(parsed) {
        let schemaObject = try JSONSerialization.jsonObject(with: rawSchemaData)
        let envelope: [String: Any] = [
            "ok": true,
            "schemaVersion": "1",
            "command": "schema",
            "data": schemaObject
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
    }

    FileHandle.standardOutput.write(rawSchemaData)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// MARK: - version

struct VersionPayload: Encodable {
    let name: String
    let version: String
    let schemaVersion: String
}

func commandVersion(_ arguments: [String]) throws {
    let parsed = try parseArguments(arguments, valued: [], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        printCommandHelp(["version"])
        return
    }
    if wantsJSON(parsed) {
        try emitJSON("version", VersionPayload(
            name: "hotkeyd",
            version: version,
            schemaVersion: "1"
        ))
    } else {
        print("hotkeyd \(version)")
    }
}

// MARK: - Helpers

/// Returns the raw executable launch path without resolving symlinks so `StrictModes.verifySecurePath`
/// can detect and reject symlinked launch paths.
func rawExecutablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0 else { return CommandLine.arguments.first ?? "" }
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) != 0 {
        buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return CommandLine.arguments.first ?? ""
        }
    }
    let raw = String(cString: buffer)
    guard raw.hasPrefix("/") else {
        return URL(fileURLWithPath: raw).path
    }
    return raw
}

func executablePath() -> String {
    URL(fileURLWithPath: rawExecutablePath()).resolvingSymlinksInPath().path
}

/// Belt and braces alongside the file watcher: ask `launchd` to deliver `SIGHUP` atomically to
/// the managed LaunchAgent job so there is zero PID-reuse signal race.
func notifyDaemonToReload() {
    guard !Paths.isEnvironmentOverrideActive else { return }
    guard LaunchAgent.isLoaded(), let pid = LaunchAgent.pid(), pid > 1, pid <= Int(pid_t.max) else {
        return
    }
    guard (try? CodeTrust.verifyRunningProcess(
        pid: pid_t(pid),
        expectedBinaryPath: LaunchAgent.installedBinaryPath(),
        allowAdhoc: LaunchAgent.installedAllowsAdhoc()
    )) != nil else {
        return
    }
    _ = tool("/bin/launchctl", ["kill", "SIGHUP", "\(LaunchAgent.domain)/\(LaunchAgent.label)"])
}

func tail(_ url: URL, lines: Int, maxBytes: Int = 200_000) -> [String] {
    guard lines > 0 else { return [] }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    let end = (try? handle.seekToEnd()) ?? 0
    let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(), !data.isEmpty else {
        return []
    }
    // Use lossy UTF-8 decoding and drop any partial leading line after a mid-file seek so landing
    // inside a multi-byte character (e.g. `…` or emoji) can never return empty.
    var text = String(decoding: data, as: UTF8.self)
    if start > 0, let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
    }
    return text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .suffix(lines)
        .map(String.init)
}

func tapState(
    daemonPID: Int? = LaunchAgent.pid(),
    sandboxed: Bool = Paths.isEnvironmentOverrideActive
) -> (installed: Bool, note: String?, secureInputActive: Bool) {
    guard let pid = daemonPID else {
        return (false, sandboxed ? "sandboxed daemon not running" : "daemon is not running", false)
    }

    // Authoritative path: atomic `runtime-state.json` written by the running daemon, cross-checked
    // against the live LaunchAgent PID so stale files from crashed processes are never trusted.
    if let state = RuntimeState.load(from: Paths.runtimeState),
       Int(state.pid) == pid {
        let note = state.secureInputActive
            ? "\(state.tapNote) (paused: Secure Event Input active)"
            : state.tapNote
        return (state.tapActive, note, state.secureInputActive)
    }

    // Fallback for an already-running pre-RuntimeState daemon: scan daemon.log bounded to the
    // current PID's startup marker (resetting on `terminating;`).
    let logLines = tail(Paths.daemonLog, lines: 800, maxBytes: 400_000)
    let pidMarker = "hotkeyd daemon starting pid=\(pid)"
    let startIndex = logLines.lastIndex(where: { $0.contains(pidMarker) }) ?? 0

    var installed = false
    var note: String?
    var secureInput = false
    for line in logLines[startIndex...] {
        guard line.contains(" daemon ") else { continue }
        if line.contains("terminating;") {
            installed = false
            note = line
        } else if line.contains("event tap installed") || line.contains("(event tap active)") {
            installed = true
            note = line
        } else if line.contains("tap could not be created")
            || line.contains("accessibility not granted")
            || line.contains("still waiting for accessibility")
            || line.contains("accessibility permission revoked") {
            installed = false
            note = line
        } else if line.contains("tap disabled by the system") {
            installed = true
            note = line
        } else if line.contains("secure event input enabled") {
            secureInput = true
        } else if line.contains("secure event input ended") {
            secureInput = false
        }
    }
    return (installed, note, secureInput)
}
