import Foundation

public struct ArgumentSpec: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String

    public init(name: String, type: String, required: Bool = true, description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }
}

public struct FlagSpec: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String

    public init(name: String, type: String, required: Bool = false, description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }

    public var bareName: String {
        name.hasPrefix("--") ? String(name.dropFirst(2)) : name
    }

    public var isBooleanSwitch: Bool {
        type == "bool"
    }
}

public struct CommandSpec: Codable, Sendable, Equatable {
    public let path: [String]
    public let aliases: [String]
    public let summary: String
    public let description: String
    public let mutating: Bool
    public let args: [ArgumentSpec]
    public let flags: [FlagSpec]
    public let examples: [String]
    public let exitCodes: [Int]

    public init(
        path: [String],
        aliases: [String] = [],
        summary: String,
        description: String,
        mutating: Bool,
        args: [ArgumentSpec] = [],
        flags: [FlagSpec] = [],
        examples: [String],
        exitCodes: [Int]
    ) {
        self.path = path
        self.aliases = aliases
        self.summary = summary
        self.description = description
        self.mutating = mutating
        self.args = args
        self.flags = flags
        self.examples = examples
        self.exitCodes = exitCodes
    }

    public var displayName: String {
        path.joined(separator: " ")
    }

    public var valuedFlagNames: Set<String> {
        Set(flags.filter { !$0.isBooleanSwitch }.map(\.bareName))
    }

    public var switchFlagNames: Set<String> {
        Set(flags.filter(\.isBooleanSwitch).map(\.bareName))
    }
}

public struct ReservedComboSpec: Codable, Sendable, Equatable {
    public let keys: String
    public let reason: String

    public init(keys: String, reason: String) {
        self.keys = keys
        self.reason = reason
    }
}

public struct ToolConventions: Codable, Sendable, Equatable {
    public let jsonFlag: String
    public let exitCodes: [String: String]
    public let env: [String: String]
    public let modifiers: [String]
    public let sidedModifiers: [String]
    public let keys: [String]
    public let keyAliases: [String: String]
    public let reservedCombos: [ReservedComboSpec]
    public let nativeFastPathPatterns: [String]
}

public struct ToolFiles: Codable, Sendable, Equatable {
    public let config: String
    public let logs: String
    public let launchAgent: String
}

public struct ToolManifest: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let schemaVersion: String
    public let summary: String
    public let whenToUse: String
    public let files: ToolFiles
    public let conventions: ToolConventions
    public let commands: [CommandSpec]
}

public enum CommandRegistry {
    public static let exitCodeDescriptions: [String: String] = [
        "0": "success",
        "2": "usage / invalid CLI flags",
        "3": "shortcut not found",
        "4": "conflict or validation error (duplicate trigger, reserved combo, out-of-range delay, caps lock conflict)",
        "5": "Accessibility permission not granted, TCC error, or event tap inactive",
        "6": "daemon not running or launchctl operation failed",
        "7": "configuration I/O, StrictModes, or code-signing check failed",
        "8": "shortcut action failed or timed out"
    ]

    public static let commands: [CommandSpec] = [
        CommandSpec(
            path: ["init"],
            summary: "Interactive onboarding wizard (and headless bootstrap) for Hotkeyd.",
            description: "Idempotently guides setup from zero to a verified firing shortcut: validates binary trust and `~/.hotkeyd` (repairing loose permissions or symlinked dotfiles safely), auto-detects starter shortcuts for your default browser and terminal when no config exists, installs the LaunchAgent with live Accessibility polling, and runs a safe two-stage live verification. Supports `--dry-run` and `--non-interactive --json` for dotfiles scripts and AI agents.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--starter", type: "minimal|empty|skip", description: "Starter preset when ~/.hotkeyd is missing or empty (minimal: 3 auto-detected double-taps, empty: blank 0600 config, skip: do not create). Required in --non-interactive mode when ~/.hotkeyd is missing."),
                FlagSpec(name: "--no-daemon", type: "bool", description: "Configure and validate ~/.hotkeyd only; skip LaunchAgent installation, Accessibility wait, and live verification (required when HOTKEYD_HOME is set)."),
                FlagSpec(name: "--no-open", type: "bool", description: "Do not open System Settings automatically when waiting for Accessibility permission."),
                FlagSpec(name: "--no-verify", type: "bool", description: "Skip the live keypress smoke test after Accessibility is active."),
                FlagSpec(name: "--allow-adhoc", type: "bool", description: "Allow a Hardened-Runtime ad-hoc signed binary (disables SELECTED_TEXT and Accessibility delegation)."),
                FlagSpec(name: "--dry-run", type: "bool", description: "Run preflight checks and app detection without mutating ~/.hotkeyd or launchd."),
                FlagSpec(name: "--non-interactive", type: "bool", description: "Never prompt on stdin; requires --starter when ~/.hotkeyd is missing and exits 5 if Accessibility permission is still pending."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope (including structured partial progress on exit 5)."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd init",
                "hotkeyd init --dry-run",
                "hotkeyd init --non-interactive --starter minimal --json",
                "hotkeyd init --no-daemon --starter minimal"
            ],
            exitCodes: [0, 2, 5, 6, 7]
        ),
        CommandSpec(
            path: ["add"],
            summary: "Bind a global keyboard shortcut, modifier double-tap, or two-step sequence.",
            description: "Adds a single-tap (`--tap`) and/or double-tap (`--double-tap`) command to `~/.hotkeyd` for `<keys>`. Supports bare modifier double-taps (`lcmd`), key combinations (`fn+space`), and two-step `<modifier> > <key>` sequences (`'fn > q'` or shell-safe `fn:q`; unsided `shift` is not allowed as a sequence leader). Accepts `<keys>` either positionally or via `--keys`. Merges into an existing entry when the other slot is free, or overwrites when `--force` (`--upsert`) is passed.",
            mutating: true,
            args: [
                ArgumentSpec(name: "keys", type: "modifier|combo|sequence", required: false, description: "Target modifier (lcmd, rshift, capsLock, fn), key combination (fn+space, capsLock+space, cmd+shift+c, fn+escape), or two-step sequence ('fn > q' or shell-safe 'fn:q'). Can also be passed via --keys."),
                ArgumentSpec(name: "command", type: "command", required: false, description: "Optional positional command shorthand: binds doubleTap when `keys` is a bare modifier, or tap when `keys` is a key combination or sequence.")
            ],
            flags: [
                FlagSpec(name: "--keys", type: "modifier|combo|sequence", description: "Target modifier, key combination, or two-step '<modifier> > <key>' (or '<modifier>:<key>') sequence."),
                FlagSpec(name: "--tap", type: "command", description: "Command to execute on a single key-combo press or two-step sequence (not valid on bare modifiers)."),
                FlagSpec(name: "--double-tap", type: "command", description: "Command to execute on a double-tap of a modifier or key combination (not valid on sequences)."),
                FlagSpec(name: "--name", type: "string", description: "Optional unique human-friendly alias for the binding."),
                FlagSpec(name: "--max-double-tap-delay", type: "ms", description: "Max double-tap interval in milliseconds (100..600, default 400 for modifiers / 250 for key combos; legacy --window also accepted)."),
                FlagSpec(name: "--max-sequence-delay", type: "ms", description: "Max delay in milliseconds between releasing step 1 and pressing step 2 in a '<modifier> > <key>' sequence (100..1500, default 250)."),
                FlagSpec(name: "--timeout", type: "ms", description: "Command execution timeout in milliseconds (1..600000, default 30000)."),
                FlagSpec(name: "--cwd", type: "path", description: "Working directory for shell execution (absolute path or ~)."),
                FlagSpec(name: "--force", type: "bool", description: "Overwrite an existing tap/doubleTap slot on the same keys binding if already bound."),
                FlagSpec(name: "--upsert", type: "bool", description: "Alias for --force."),
                FlagSpec(name: "--pass-through", type: "bool", description: "Allow the matched key combination or sequence step-2 key to pass through to the focused application instead of swallowing it."),
                FlagSpec(name: "--no-pass-through", type: "bool", description: "Clear passThrough when updating an existing binding."),
                FlagSpec(name: "--allow-accessibility", type: "bool", description: "Opt in to inheriting the daemon's Accessibility TCC attribution for trusted scripts (e.g. yabai/osascript UI scripting)."),
                FlagSpec(name: "--no-allow-accessibility", type: "bool", description: "Revoke allowAccessibility when updating an existing binding."),
                FlagSpec(name: "--dry-run", type: "bool", description: "Validate and preview the resulting shortcut without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd add lcmd 'open -a \"Google Chrome\"'",
                "hotkeyd add fn+space 'open -a Notes'",
                "hotkeyd add fn:q 'open -a Safari'",
                "hotkeyd add 'rcmd > f1' 'open ~/Projects' --max-sequence-delay 400",
                "hotkeyd add fn+escape --tap 'osascript -e \"set volume output muted true\"' --double-tap 'osascript -e \"set volume output volume 100\"'",
                "hotkeyd add lcmd --double-tap 'open -a Safari' --force"
            ],
            exitCodes: [0, 2, 4, 7]
        ),
        CommandSpec(
            path: ["set"],
            summary: "Create, overwrite, or update metadata on a shortcut binding in place.",
            description: "Creates or updates a shortcut in `~/.hotkeyd`. When a command (`<command>`, `--tap`, or `--double-tap`) is passed, creates or overwrites those slot(s). When no command is passed, updates metadata (`--name`, `--timeout`, `--cwd`, delays, flags, or `--clear-*`) on an existing shortcut matched by keys or name without re-specifying its command.",
            mutating: true,
            args: [
                ArgumentSpec(name: "keys|name", type: "string", required: false, description: "Target modifier, key combination, sequence ('fn > q' or 'fn:q'), or existing shortcut name (for metadata updates)."),
                ArgumentSpec(name: "command", type: "command", required: false, description: "Optional positional command shorthand (doubleTap for modifiers, tap for key combos and sequences).")
            ],
            flags: [
                FlagSpec(name: "--keys", type: "modifier|combo|sequence", description: "Target modifier, key combination, or two-step '<modifier> > <key>' (or '<modifier>:<key>') sequence."),
                FlagSpec(name: "--tap", type: "command", description: "Command to execute on a single key-combo press or two-step sequence."),
                FlagSpec(name: "--double-tap", type: "command", description: "Command to execute on a double-tap of a modifier or key combination."),
                FlagSpec(name: "--name", type: "string", description: "Optional unique human-friendly alias for the binding."),
                FlagSpec(name: "--max-double-tap-delay", type: "ms", description: "Max double-tap interval in milliseconds (100..600; legacy --window also accepted)."),
                FlagSpec(name: "--max-sequence-delay", type: "ms", description: "Max delay in milliseconds between step 1 release and step 2 press (100..1500)."),
                FlagSpec(name: "--timeout", type: "ms", description: "Command execution timeout in milliseconds (1..600000, default 30000)."),
                FlagSpec(name: "--cwd", type: "path", description: "Working directory for shell execution (absolute path or ~)."),
                FlagSpec(name: "--clear-name", type: "bool", description: "Remove the optional name from an existing shortcut."),
                FlagSpec(name: "--clear-cwd", type: "bool", description: "Clear the custom working directory on an existing shortcut."),
                FlagSpec(name: "--clear-timeout", type: "bool", description: "Reset timeoutMs back to the 30000ms default on an existing shortcut."),
                FlagSpec(name: "--clear-delays", type: "bool", description: "Reset custom maxDoubleTapDelayMs and maxSequenceDelayMs overrides on an existing shortcut."),
                FlagSpec(name: "--pass-through", type: "bool", description: "Allow the matched key combination or sequence step-2 key to pass through to the focused application."),
                FlagSpec(name: "--no-pass-through", type: "bool", description: "Clear passThrough when updating an existing binding."),
                FlagSpec(name: "--allow-accessibility", type: "bool", description: "Opt in to inheriting the daemon's Accessibility TCC attribution."),
                FlagSpec(name: "--no-allow-accessibility", type: "bool", description: "Revoke allowAccessibility when updating an existing binding."),
                FlagSpec(name: "--dry-run", type: "bool", description: "Validate and preview the resulting shortcut without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd set lcmd 'open -a \"Google Chrome\"'",
                "hotkeyd set fn:q 'open -a Safari'",
                "hotkeyd set fn+space --name 'Screenshot' --timeout 60000",
                "hotkeyd set fn+escape --double-tap 'osascript -e \"set volume output volume 80\"'"
            ],
            exitCodes: [0, 2, 3, 4, 7]
        ),
        CommandSpec(
            path: ["list"],
            aliases: ["ls"],
            summary: "List configured shortcuts in a width-aware table.",
            description: "Prints all shortcuts from `~/.hotkeyd` in a readable, terminal-width-aware table (collapsing multiline scripts by default; pass `--full` for complete commands, or use `hotkeyd show <keys|name>`).",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--full", type: "bool", description: "Display full, untruncated command strings in text output."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope with explicit boolean flags and execution metadata."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd list",
                "hotkeyd list --full",
                "hotkeyd ls --json"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["show"],
            summary: "Inspect a single shortcut in full detail.",
            description: "Displays all fields, full tap/doubleTap commands, flags, delays, execution mode, and SELECTED_TEXT usage for the shortcut matching `<keys|name>`.",
            mutating: false,
            args: [
                ArgumentSpec(name: "keys|name", type: "string", required: true, description: "Canonical keys binding (e.g. lcmd, fn+space, 'fn > q', fn:q, doubleTap:lcmd) or shortcut name.")
            ],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd show fn+space",
                "hotkeyd show 'fn > q' --json"
            ],
            exitCodes: [0, 2, 3, 4, 7]
        ),
        CommandSpec(
            path: ["remove"],
            aliases: ["rm"],
            summary: "Remove a shortcut or clear one of its tap/doubleTap slots.",
            description: "Removes the shortcut matching `<keys|name>` from `~/.hotkeyd`. When `--tap` or `--double-tap` is passed on an entry that has both slots populated, clears only that slot (exiting 3 if the requested slot is not set).",
            mutating: true,
            args: [
                ArgumentSpec(name: "keys|name", type: "string", required: true, description: "Canonical keys binding (e.g. lcmd, fn+escape, 'fn > q', fn:q, doubleTap:lcmd) or optional shortcut name.")
            ],
            flags: [
                FlagSpec(name: "--tap", type: "bool", description: "Remove only the single-tap slot (fails with exit 3 if tap is not set)."),
                FlagSpec(name: "--double-tap", type: "bool", description: "Remove only the double-tap slot (fails with exit 3 if doubleTap is not set)."),
                FlagSpec(name: "--dry-run", type: "bool", description: "Preview what would be removed without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd remove lcmd",
                "hotkeyd rm fn:q",
                "hotkeyd rm fn+escape --double-tap"
            ],
            exitCodes: [0, 2, 3, 4, 7]
        ),
        CommandSpec(
            path: ["enable"],
            summary: "Re-enable a disabled shortcut.",
            description: "Sets `enabled: true` on the shortcut matching `<keys|name>`, validates for trigger conflicts, saves `~/.hotkeyd`, and signals the daemon to reload.",
            mutating: true,
            args: [
                ArgumentSpec(name: "keys|name", type: "string", required: true, description: "Canonical keys binding or shortcut name.")
            ],
            flags: [
                FlagSpec(name: "--dry-run", type: "bool", description: "Validate enabling the shortcut without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd enable fn+space",
                "hotkeyd enable Screenshot --json"
            ],
            exitCodes: [0, 2, 3, 4, 7]
        ),
        CommandSpec(
            path: ["disable"],
            summary: "Temporarily disable a shortcut without deleting it.",
            description: "Sets `enabled: false` on the shortcut matching `<keys|name>`, saves `~/.hotkeyd`, and signals the daemon to reload.",
            mutating: true,
            args: [
                ArgumentSpec(name: "keys|name", type: "string", required: true, description: "Canonical keys binding or shortcut name.")
            ],
            flags: [
                FlagSpec(name: "--dry-run", type: "bool", description: "Preview disabling the shortcut without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd disable fn+space",
                "hotkeyd disable Screenshot --json"
            ],
            exitCodes: [0, 2, 3, 4, 7]
        ),
        CommandSpec(
            path: ["validate"],
            summary: "Validate ~/.hotkeyd permissions, syntax, triggers, and rollover warnings.",
            description: "Checks `~/.hotkeyd` against `StrictModes`, JSON decoding, trigger/name validation rules, and flags `mod+key` vs `mod > key` rollover overlaps without mutating anything.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd validate",
                "hotkeyd validate --json"
            ],
            exitCodes: [0, 2, 4, 7]
        ),
        CommandSpec(
            path: ["edit"],
            summary: "Safely edit ~/.hotkeyd in $VISUAL/$EDITOR with pre-save validation.",
            description: "Opens a temporary `0600` copy of `~/.hotkeyd` in `$VISUAL` or `$EDITOR` (default `/usr/bin/vi`), validates JSON and shortcut rules on exit, and atomically writes `~/.hotkeyd` (`0600`) only when valid.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd edit"
            ],
            exitCodes: [0, 2, 4, 7, 8]
        ),
        CommandSpec(
            path: ["run"],
            summary: "Fire a shortcut's action immediately without pressing its keys.",
            description: "Executes the shortcut matching `<keys|name>`. Dispatches detached by default (`detached: true`); pass `--wait` to run synchronously and capture `{exitCode, stdout, stderr, durationMilliseconds, detached: false}`.",
            mutating: false,
            args: [
                ArgumentSpec(name: "keys|name", type: "string", required: true, description: "Canonical keys binding (e.g. lcmd, fn+space, 'fn > q', fn:q) or optional shortcut name.")
            ],
            flags: [
                FlagSpec(name: "--tap", type: "bool", description: "Select the single-tap command when the entry defines both tap and doubleTap."),
                FlagSpec(name: "--double-tap", type: "bool", description: "Select the double-tap command when the entry defines both tap and doubleTap."),
                FlagSpec(name: "--wait", type: "bool", description: "Wait for completion and return exit code, duration, stdout, and stderr."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd run fn+space",
                "hotkeyd run fn:q --wait --json",
                "hotkeyd run fn+escape --double-tap --wait --json"
            ],
            exitCodes: [0, 2, 3, 4, 7, 8]
        ),
        CommandSpec(
            path: ["migrate-actions"],
            summary: "Normalize ~/.hotkeyd formatting and report native NSWorkspace fast-path commands.",
            description: "Rewrites `~/.hotkeyd` in canonical one-object-per-line formatting and audits which commands automatically use the native `NSWorkspace` fast-path. Preserves all shortcut `name` values by default (pass `--strip-names` to remove names).",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--dry-run", type: "bool", description: "Report native fast-path coverage without modifying ~/.hotkeyd."),
                FlagSpec(name: "--keep-names", type: "bool", description: "Preserve shortcut names (now the default behavior)."),
                FlagSpec(name: "--strip-names", type: "bool", description: "Explicitly remove optional name fields from all shortcuts."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd migrate-actions --dry-run",
                "hotkeyd migrate-actions --json"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["logs"],
            summary: "Show or follow recent daemon and action log lines.",
            description: "Tails `daemon.log` and `actions.log` from `~/Library/Application Support/Hotkeyd/logs/` with local timestamps by default (pass `--follow` / `-f` to stream live updates, or `--utc` for raw UTC ISO8601 timestamps).",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--lines", type: "int", description: "Number of recent lines to display per log file (default 50)."),
                FlagSpec(name: "--daemon", type: "bool", description: "Show only daemon.log."),
                FlagSpec(name: "--actions", type: "bool", description: "Show only actions.log."),
                FlagSpec(name: "--follow", type: "bool", description: "Stream new log lines as they are written (-f)."),
                FlagSpec(name: "--utc", type: "bool", description: "Display raw UTC ISO8601 timestamps instead of local time."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd logs",
                "hotkeyd logs --lines 20 --actions",
                "hotkeyd logs -f",
                "hotkeyd logs --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["daemon", "status"],
            summary: "Show daemon, event tap, and configuration status.",
            description: "Alias for `hotkeyd status`: reports config validity, daemon PID, authoritative event tap state, Secure Event Input status, and recent actions.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon status",
                "hotkeyd daemon status --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["daemon", "start"],
            summary: "Start the LaunchAgent daemon (idempotent if already running).",
            description: "Ensures `io.github.jardondiego.hotkeyd.daemon` is running under `launchd`. If it is already running, reports its PID without restarting; if not installed yet, installs and bootstraps it.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon start",
                "hotkeyd daemon start --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["daemon", "stop"],
            summary: "Stop the running LaunchAgent daemon and restore Caps Lock.",
            description: "Boots out `gui/$UID/io.github.jardondiego.hotkeyd.daemon` and restores normal Caps Lock behavior if remapped.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon stop",
                "hotkeyd daemon stop --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["daemon", "reload"],
            summary: "Signal the running daemon (SIGHUP) to reload ~/.hotkeyd immediately.",
            description: "Sends `SIGHUP` to the verified running LaunchAgent daemon without restarting the process or dropping the event tap.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon reload",
                "hotkeyd daemon reload --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["daemon", "restart"],
            summary: "Restart the running LaunchAgent daemon.",
            description: "Runs `launchctl kickstart -k gui/$UID/io.github.jardondiego.hotkeyd.daemon` so the daemon reloads cleanly under launchd.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon restart",
                "hotkeyd daemon restart --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["daemon", "install"],
            summary: "Install and start the LaunchAgent daemon.",
            description: "Verifies binary code trust and `StrictModes` path ownership, writes `~/Library/LaunchAgents/io.github.jardondiego.hotkeyd.daemon.plist` (`0600`), and bootstraps the daemon under `launchd`.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--binary", type: "path", description: "Explicit path to the signed `hotkeyd` binary (defaults to current executable)."),
                FlagSpec(name: "--allow-adhoc", type: "bool", description: "Allow ad-hoc Hardened Runtime signatures instead of requiring a certificate-anchored leaf."),
                FlagSpec(name: "--no-open", type: "bool", description: "Do not open System Settings > Accessibility after installing."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon install",
                "hotkeyd daemon install --binary ~/.local/bin/hotkeyd --no-open --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["daemon", "uninstall"],
            summary: "Stop and remove the LaunchAgent daemon and restore Caps Lock.",
            description: "Boots out `gui/$UID/io.github.jardondiego.hotkeyd.daemon`, removes the LaunchAgent plist, and clears any active Caps Lock -> F18 HID remap.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon uninstall",
                "hotkeyd daemon uninstall --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["daemon", "logs"],
            summary: "Show or follow recent daemon and action log lines.",
            description: "Alias for `hotkeyd logs`: tails or follows `daemon.log` and `actions.log`.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--lines", type: "int", description: "Number of recent lines to display per log file (default 50)."),
                FlagSpec(name: "--daemon", type: "bool", description: "Show only daemon.log."),
                FlagSpec(name: "--actions", type: "bool", description: "Show only actions.log."),
                FlagSpec(name: "--follow", type: "bool", description: "Stream new log lines as they are written (-f)."),
                FlagSpec(name: "--utc", type: "bool", description: "Display raw UTC ISO8601 timestamps instead of local time."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon logs",
                "hotkeyd daemon logs --lines 100 --daemon",
                "hotkeyd daemon logs -f"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["daemon", "run"],
            summary: "Run the event-tap daemon in the foreground (invoked by launchd).",
            description: "Verifies binary signature and `StrictModes`, acquires an exclusive daemon lock, installs the session `CGEventTap`, watches `~/.hotkeyd`, persists `runtime-state.json`, and manages the Caps Lock HID remap.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--allow-adhoc", type: "bool", description: "Allow ad-hoc Hardened Runtime signatures."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd daemon run"
            ],
            exitCodes: [0, 2, 5, 6]
        ),
        CommandSpec(
            path: ["pause"],
            summary: "Temporarily disarm all shortcuts (with optional auto-resume timer).",
            description: "Writes a `0600` pause state file and signals the daemon via `SIGHUP` to pass all key events through untouched and temporarily restore physical Caps Lock. Pass `--for <duration>` (e.g. `15m`, `1h30m`, `5s..24h`) to auto-resume on timer expiry (including across sleep/wake), or omit `--for` to stay paused until `hotkeyd resume`.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--for", type: "duration", description: "Auto-resume after duration (e.g. 30s, 15m, 1h, 1h30m; range 5s..24h)."),
                FlagSpec(name: "--reason", type: "text", description: "Optional short reason shown in `hotkeyd status` (e.g. pairing, gaming, presenting)."),
                FlagSpec(name: "--toggle", type: "bool", description: "Resume immediately if already paused; otherwise pause."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd pause --for 15m --reason pairing",
                "hotkeyd pause --for 1h",
                "hotkeyd pause --toggle",
                "hotkeyd pause --json"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["resume"],
            summary: "Re-arm shortcuts immediately after `hotkeyd pause`.",
            description: "Clears the pause state file and signals the daemon via `SIGHUP` to resume listening for shortcuts and re-sync Caps Lock remapping. Idempotent when shortcuts are already active.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd resume",
                "hotkeyd resume --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["panic"],
            summary: "Emergency stop: boot out the daemon and restore Caps Lock immediately.",
            description: "Stops the LaunchAgent daemon, removes the Caps Lock -> F18 HID remap, and forces the IOHIDSystem Caps Lock modifier state off.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd panic",
                "hotkeyd panic --json"
            ],
            exitCodes: [0, 2, 6]
        ),
        CommandSpec(
            path: ["caps", "status"],
            summary: "Show the Caps Lock HID remap state and IOHIDSystem lock state.",
            description: "Reports whether Caps Lock is unmapped (`off`), remapped to F18 by Hotkeyd (`enabled`), or owned by another tool (`foreign`), alongside the hardware modifier lock state (`on`/`off`).",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd caps status",
                "hotkeyd caps --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["caps", "on"],
            summary: "Remap Caps Lock to F18 at the HID level.",
            description: "Forces the IOHIDSystem Caps Lock state off first (preventing uppercase lockout) and applies the Caps Lock -> F18 `hidutil` mapping.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd caps on"
            ],
            exitCodes: [0, 2, 4, 8]
        ),
        CommandSpec(
            path: ["caps", "off"],
            summary: "Restore normal Caps Lock behavior.",
            description: "Clears the Caps Lock -> F18 `hidutil` mapping without requiring the daemon to be running.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd caps off"
            ],
            exitCodes: [0, 2, 8]
        ),
        CommandSpec(
            path: ["caps", "reset"],
            summary: "Force the IOHIDSystem Caps Lock modifier state off.",
            description: "Clears a stuck uppercase Caps Lock state directly via `IOHIDSetModifierLockState` while leaving any F18 remap intact.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd caps reset"
            ],
            exitCodes: [0, 2, 8]
        ),
        CommandSpec(
            path: ["peek", "toggle"],
            summary: "Toggle the pinned shortcut reference overlay or Spotlight Search HUD (or print offline with --terminal).",
            description: "Default action for bare `hotkeyd peek`. Signals the running daemon via `SIGUSR1` to toggle the pinned bento cheatsheet overlay, or pass `--search` (`SIGUSR2`) to toggle the interactive Spotlight Search HUD. Pass `--terminal` (optionally with `--search --query <text>`) to render offline in the terminal.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--search", type: "bool", description: "Toggle the interactive Spotlight Search HUD (or run fuzzy search with `--terminal`)."),
                FlagSpec(name: "--terminal", type: "bool", description: "Print the grouped cheatsheet or fuzzy search results in the terminal instead of toggling the desktop overlay."),
                FlagSpec(name: "--query", type: "text", description: "Fuzzy search query to evaluate offline (requires `--search --terminal`)."),
                FlagSpec(name: "--show-disabled", type: "bool", description: "Include disabled shortcuts when rendering with `--terminal`."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd peek",
                "hotkeyd peek --search",
                "hotkeyd peek --terminal",
                "hotkeyd peek --search --terminal --query qr",
                "hotkeyd peek toggle"
            ],
            exitCodes: [0, 2, 6, 7]
        ),
        CommandSpec(
            path: ["peek", "status"],
            summary: "Show peek overlay and Spotlight Search HUD settings and active triggers.",
            description: "Displays whether peek is enabled, configured vs active hold triggers (noting when `capsLock` is dormant due to having no enabled `capsLock` bindings), hold delay in milliseconds, optional hands-free overlay and Spotlight Search toggle hotkeys, dimming mode, and disabled-shortcut visibility.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd peek status",
                "hotkeyd peek status --json"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["peek", "enable"],
            summary: "Enable the hold-modifier peek overlay in ~/.hotkeyd.",
            description: "Sets `peek.enabled = true` in `~/.hotkeyd` atomically and signals the daemon to reload.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--dry-run", type: "bool", description: "Validate and preview the change without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd peek enable",
                "hotkeyd peek enable --json"
            ],
            exitCodes: [0, 2, 4, 7]
        ),
        CommandSpec(
            path: ["peek", "disable"],
            summary: "Disable the hold-modifier peek overlay in ~/.hotkeyd.",
            description: "Sets `peek.enabled = false` in `~/.hotkeyd` atomically and signals the daemon to reload (hiding any active overlay).",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--dry-run", type: "bool", description: "Validate and preview the change without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd peek disable",
                "hotkeyd peek disable --json"
            ],
            exitCodes: [0, 2, 4, 7]
        ),
        CommandSpec(
            path: ["peek", "set"],
            summary: "Customize peek hold triggers, delay, overlay/search toggle hotkeys, dimming, or reset to defaults.",
            description: "Atomically updates the optional top-level `peek` block in `~/.hotkeyd`, validates delay bounds (300..2000 ms) and toggle/search-toggle key collisions against existing shortcuts, and signals the daemon to reload.",
            mutating: true,
            args: [],
            flags: [
                FlagSpec(name: "--triggers", type: "list", description: "Comma-separated hold modifier triggers to open the overlay (default `fn`; e.g. `fn,capsLock`, `none`)."),
                FlagSpec(name: "--delay", type: "ms", description: "Hold duration in milliseconds before showing the overlay (300..2000; default 450)."),
                FlagSpec(name: "--toggle", type: "keys", description: "Key combo, two-step sequence (`fn:/`, `fn:h`), or bare modifier double-tap to toggle the pinned overlay hands-free."),
                FlagSpec(name: "--clear-toggle", type: "bool", description: "Remove any configured hands-free toggle hotkey."),
                FlagSpec(name: "--search-toggle", type: "keys", description: "Key combo, two-step sequence (`fn:s`), or bare modifier double-tap to toggle the Spotlight Search HUD directly."),
                FlagSpec(name: "--clear-search-toggle", type: "bool", description: "Remove any configured Spotlight Search toggle hotkey."),
                FlagSpec(name: "--dim", type: "bool", description: "Dim unmatched shortcuts when spotlighting a held modifier while pinned (default)."),
                FlagSpec(name: "--no-dim", type: "bool", description: "Keep unmatched shortcuts brighter when spotlighting a held modifier while pinned."),
                FlagSpec(name: "--show-disabled", type: "bool", description: "Show disabled shortcuts inside the peek overlay."),
                FlagSpec(name: "--hide-disabled", type: "bool", description: "Hide disabled shortcuts inside the peek overlay (default)."),
                FlagSpec(name: "--reset", type: "bool", description: "Reset all peek settings back to built-in defaults (omits the `peek` block from ~/.hotkeyd)."),
                FlagSpec(name: "--dry-run", type: "bool", description: "Validate and preview the change without writing ~/.hotkeyd."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd peek set --triggers fn --delay 450",
                "hotkeyd peek set --toggle fn:/",
                "hotkeyd peek set --search-toggle fn:s",
                "hotkeyd peek set --no-dim",
                "hotkeyd peek set --clear-toggle --clear-search-toggle",
                "hotkeyd peek set --reset"
            ],
            exitCodes: [0, 2, 4, 7]
        ),
        CommandSpec(
            path: ["status"],
            summary: "Report config validity, daemon PID, event tap state, and recent actions.",
            description: "Summarizes the current operational state of Hotkeyd from atomic `runtime-state.json` (cross-checked against LaunchAgent PID) and tails the last 5 entries from `actions.log`.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd status",
                "hotkeyd status --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["doctor"],
            summary: "Run all health, TCC, LaunchAgent, Caps Lock, and code-signing checks.",
            description: "Verifies config permissions and syntax, TCC responsibility disclaim readiness, LaunchAgent state, daemon PID, authoritative event tap status, Caps Lock remap/state, and Hardened Runtime leaf-anchored code signing. Exits non-zero whenever any check fails.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd doctor",
                "hotkeyd doctor --json"
            ],
            exitCodes: [0, 2, 4, 5, 6, 7]
        ),
        CommandSpec(
            path: ["describe"],
            summary: "Emit the machine-readable manifest of all commands, flags, keys, and exit codes.",
            description: "Self-description entrypoint for AI agents and tooling. Outputs the complete `ToolManifest` as a JSON envelope (`--json` is implied when requested or piped).",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd describe --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["schema"],
            summary: "Emit JSON Schema (draft 2020-12) for `~/.hotkeyd` or a single shortcut object.",
            description: "Outputs the formal JSON Schema for `config` (default) or `shortcut` so agents and editors can validate `~/.hotkeyd`.",
            mutating: false,
            args: [
                ArgumentSpec(name: "target", type: "config|shortcut", required: false, description: "Schema target to emit (`config` by default, or `shortcut`).")
            ],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Wrap the JSON Schema in the standard `{ok, schemaVersion, command, data}` envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd schema",
                "hotkeyd schema shortcut --json"
            ],
            exitCodes: [0, 2]
        ),
        CommandSpec(
            path: ["stats"],
            summary: "Show shortcut usage counts, latency percentiles, failures, and unused bindings from actions.log.",
            description: "Analyzes retained `actions.log` (and rotated `actions.log.1`) alongside `~/.hotkeyd` with zero extra tracking. Reports total fires, success rate, native fast-path vs shell latency (average, median, p95), failing or slow shortcuts, and enabled shortcuts with zero fires in the selected window.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--since", type: "window", description: "Filter events to a trailing window (`all`, `24h`, `7d`, `30d`, `2w`, `30m`, or `YYYY-MM-DD`; default `all`)."),
                FlagSpec(name: "--top", type: "count", description: "Maximum number of top shortcuts to display (positive integer; default 15 in text output)."),
                FlagSpec(name: "--unused", type: "bool", description: "List all enabled shortcuts that had zero fires in the observed window."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd stats",
                "hotkeyd stats --since 7d --top 10",
                "hotkeyd stats --unused",
                "hotkeyd stats --json"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["completions"],
            summary: "Generate or install shell completions (zsh, bash, fish) with live ~/.hotkeyd shortcut completion.",
            description: "Generates a self-contained completion script for zsh, bash, or fish directly from the command registry. Includes dynamic tab-completion of shortcut names and canonical keys from `~/.hotkeyd` (including enabled/disabled filtering for `enable` and `disable`). Pass `--install` to write to your shell's standard completion directory.",
            mutating: false,
            args: [
                ArgumentSpec(name: "shell", type: "zsh|bash|fish", required: true, description: "Target shell: zsh, bash, or fish.")
            ],
            flags: [
                FlagSpec(name: "--install", type: "bool", description: "Write the generated script atomically to the standard user completion directory for the chosen shell."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope containing script, installPath, and activationHint."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd completions zsh --install",
                "hotkeyd completions bash --install",
                "hotkeyd completions fish --install",
                "hotkeyd completions zsh"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["man"],
            summary: "Generate or install the hotkeyd(1) manual page.",
            description: "Generates a `man(7)` troff manual page (`hotkeyd.1`) directly from the live command registry, flags, key syntax, and exit codes. Pass `--install` to install `~/.local/share/man/man1/hotkeyd.1` so `man hotkeyd` works directly.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--install", type: "bool", description: "Install hotkeyd.1 atomically to ~/.local/share/man/man1/hotkeyd.1 (or $HOTKEYD_HOME/share/man/man1/hotkeyd.1)."),
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope containing the manual page content and installPath."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd man --install",
                "hotkeyd man | mandoc | less"
            ],
            exitCodes: [0, 2, 7]
        ),
        CommandSpec(
            path: ["version"],
            aliases: ["--version", "-v"],
            summary: "Print the Hotkeyd version and schema version.",
            description: "Displays the binary version string and JSON envelope schema version.",
            mutating: false,
            args: [],
            flags: [
                FlagSpec(name: "--json", type: "bool", description: "Emit machine-readable JSON envelope."),
                FlagSpec(name: "--help", type: "bool", description: "Show command help.")
            ],
            examples: [
                "hotkeyd version",
                "hotkeyd version --json"
            ],
            exitCodes: [0, 2]
        )
    ]

    public static func findCommand(matching tokens: [String]) -> CommandSpec? {
        let cleaned = tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        if let exact = commands.first(where: { $0.path == cleaned }) {
            return exact
        }
        if cleaned.count == 1, let byAlias = commands.first(where: { $0.aliases.contains(cleaned[0]) }) {
            return byAlias
        }
        return nil
    }

    public static func findGroupCommands(group: String) -> [CommandSpec] {
        commands.filter { $0.path.first == group }
    }

    public static func formatHelp(for spec: CommandSpec) -> String {
        var lines: [String] = []
        let argUsage = spec.args.map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
        let flagUsage = spec.flags.isEmpty ? "" : " [options]"
        let usageLine = "hotkeyd \(spec.displayName)" + (argUsage.isEmpty ? "" : " \(argUsage)") + flagUsage

        lines.append("hotkeyd \(spec.displayName) — \(spec.summary)")
        lines.append("")
        lines.append("USAGE")
        lines.append("  \(usageLine)")
        if !spec.aliases.isEmpty {
            lines.append("  aliases: \(spec.aliases.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("DESCRIPTION")
        lines.append("  \(spec.description)")

        if !spec.args.isEmpty {
            lines.append("")
            lines.append("ARGUMENTS")
            let width = max(14, spec.args.map { $0.name.count + 4 }.max() ?? 14)
            for arg in spec.args {
                let token = arg.required ? "<\(arg.name)>" : "[\(arg.name)]"
                let padded = token.count >= width ? token : token + String(repeating: " ", count: width - token.count)
                lines.append("  \(padded)  \(arg.description)")
            }
        }

        if !spec.flags.isEmpty {
            lines.append("")
            lines.append("FLAGS")
            let formattedFlags: [(label: String, desc: String)] = spec.flags.map { flag in
                let label = flag.isBooleanSwitch ? flag.name : "\(flag.name) <\(flag.type)>"
                return (label, flag.description)
            }
            let width = max(18, formattedFlags.map(\.label.count).max() ?? 18)
            for item in formattedFlags {
                let padded = item.label.count >= width
                    ? item.label
                    : item.label + String(repeating: " ", count: width - item.label.count)
                lines.append("  \(padded)  \(item.desc)")
            }
        }

        if !spec.examples.isEmpty {
            lines.append("")
            lines.append("EXAMPLES")
            for example in spec.examples {
                lines.append("  \(example)")
            }
        }

        if !spec.exitCodes.isEmpty {
            lines.append("")
            lines.append("EXIT CODES")
            let parts = spec.exitCodes.map { code -> String in
                let short = exitCodeDescriptions[String(code)] ?? ""
                return "\(code) (\(short))"
            }
            lines.append("  " + parts.joined(separator: " · "))
        }

        return lines.joined(separator: "\n")
    }

    public static func formatGroupHelp(group: String) -> String? {
        let groupSpecs = findGroupCommands(group: group)
        guard !groupSpecs.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("hotkeyd \(group) — \(group) subcommands")
        lines.append("")
        lines.append("USAGE")
        lines.append("  hotkeyd \(group) <subcommand> [options]")
        lines.append("")
        lines.append("SUBCOMMANDS")
        let width = max(18, groupSpecs.map { $0.displayName.count }.max() ?? 18)
        for spec in groupSpecs {
            let padded = spec.displayName.count >= width
                ? spec.displayName
                : spec.displayName + String(repeating: " ", count: width - spec.displayName.count)
            lines.append("  \(padded)  \(spec.summary)")
        }
        lines.append("")
        lines.append("Run `hotkeyd help \(group) <subcommand>` for details on a subcommand.")
        return lines.joined(separator: "\n")
    }

    public static func manifest(
        version: String,
        configPath: String,
        logsPath: String,
        launchAgentPath: String
    ) -> ToolManifest {
        ToolManifest(
            name: "hotkeyd",
            version: version,
            schemaVersion: "1",
            summary: "Global keyboard shortcuts, two-step sequences, and modifier double-tap gestures for macOS, driven from the CLI.",
            whenToUse: "Use when the user wants to bind, inspect, validate, run, or diagnose global keyboard shortcuts, two-step '<modifier> > <key>' sequences, or modifier double-tap gestures on macOS.",
            files: ToolFiles(
                config: configPath,
                logs: logsPath,
                launchAgent: launchAgentPath
            ),
            conventions: ToolConventions(
                jsonFlag: "Pass --json on CLI commands for a structured {ok, schemaVersion, command, data} or {ok: false, schemaVersion, error: {code, kind, message, hint?}} envelope.",
                exitCodes: exitCodeDescriptions,
                env: [
                    "HOTKEYD_HOME": "Override the state and config directory (for sandboxing and automated tests).",
                    "SELECTED_TEXT": "Automatically populated in child shell environments when a shortcut's tap or doubleTap command string contains 'SELECTED_TEXT' (reads the frontmost app's selection via macOS Accessibility without touching the clipboard or requiring --allow-accessibility).",
                    "SELECTED_TEXT_STATUS": "Populated alongside SELECTED_TEXT with one of: ok, empty, secure, disabled, or untrusted."
                ],
                modifiers: ["cmd", "opt", "ctrl", "shift", "fn", "capsLock"],
                sidedModifiers: ["lcmd", "rcmd", "lopt", "ropt", "lctrl", "rctrl", "lshift", "rshift"],
                keys: KeyCodes.allKeyNames,
                keyAliases: KeyCodes.allAliases,
                reservedCombos: KeyCombo.reservedDescriptions.map {
                    ReservedComboSpec(keys: $0.keys, reason: $0.reason)
                },
                nativeFastPathPatterns: [
                    "open -a <App> [--args ...]",
                    "open <https://... | http://...>",
                    "open <~ | ~/dir | /abs/dir>"
                ]
            ),
            commands: commands
        )
    }

    public static let shortcutJSONSchema: [String: Any] = [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "HotkeydShortcut",
        "description": "A single global keyboard shortcut, modifier double-tap, or two-step sequence entry in ~/.hotkeyd.",
        "type": "object",
        "additionalProperties": false,
        "required": ["keys"],
        "properties": [
            "keys": [
                "type": "string",
                "description": "Modifier (cmd, lcmd, rcmd, opt, lopt, ropt, ctrl, lctrl, rctrl, shift, lshift, rshift, fn, capsLock), key combination (e.g. fn+space, capsLock+space, cmd+shift+c, fn+escape), or two-step sequence '<modifier> > <key>' (e.g. fn > q, rcmd > space, capsLock > a; unsided shift is forbidden as a sequence leader)."
            ],
            "tap": [
                "type": "string",
                "minLength": 1,
                "description": "Command executed on a single press of a key combination or two-step sequence (not allowed on bare modifiers). Commands referencing SELECTED_TEXT automatically receive SELECTED_TEXT and SELECTED_TEXT_STATUS without requiring allowAccessibility."
            ],
            "doubleTap": [
                "type": "string",
                "minLength": 1,
                "description": "Command executed on a double-tap of a modifier or key combination (not allowed on sequences). Commands referencing SELECTED_TEXT automatically receive SELECTED_TEXT and SELECTED_TEXT_STATUS without requiring allowAccessibility."
            ],
            "name": [
                "type": "string",
                "minLength": 1,
                "description": "Optional unique human-readable alias (must not collide with another shortcut's canonical keys string)."
            ],
            "maxDoubleTapDelayMs": [
                "type": "integer",
                "minimum": 100,
                "maximum": 600,
                "description": "Optional double-tap max delay override in milliseconds (default 400 for modifiers, 250 for key combos). Mutually exclusive with legacy windowMs."
            ],
            "windowMs": [
                "type": "integer",
                "minimum": 100,
                "maximum": 600,
                "deprecated": true,
                "description": "Legacy alias for maxDoubleTapDelayMs accepted on read and upgraded on save. Mutually exclusive with maxDoubleTapDelayMs."
            ],
            "maxSequenceDelayMs": [
                "type": "integer",
                "minimum": 100,
                "maximum": 1500,
                "description": "Optional two-step sequence max delay override in milliseconds after releasing step 1 (default 250)."
            ],
            "timeoutMs": [
                "type": "integer",
                "minimum": 1,
                "maximum": 600000,
                "description": "Optional shell command timeout in milliseconds (default 30000)."
            ],
            "cwd": [
                "type": "string",
                "description": "Optional working directory (absolute path or ~)."
            ],
            "passThrough": [
                "type": "boolean",
                "default": false,
                "description": "When true on a key combination or sequence, lets the matched key event pass through to the focused app instead of swallowing it."
            ],
            "allowAccessibility": [
                "type": "boolean",
                "default": false,
                "description": "When true, child shell processes retain the daemon's Accessibility TCC attribution instead of disclaiming it."
            ],
            "enabled": [
                "type": "boolean",
                "default": true,
                "description": "When false, the binding is kept in .hotkeyd but not armed in the daemon."
            ]
        ],
        "anyOf": [
            ["required": ["tap"]],
            ["required": ["doubleTap"]]
        ],
        "not": [
            "required": ["maxDoubleTapDelayMs", "windowMs"]
        ]
    ]

    public static let configJSONSchema: [String: Any] = [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "HotkeydConfig",
        "description": "Schema for ~/.hotkeyd (mode 0600, one compact JSON object per line inside shortcuts).",
        "type": "object",
        "additionalProperties": false,
        "required": ["shortcuts"],
        "properties": [
            "version": [
                "type": "integer",
                "const": 1,
                "description": "Optional legacy format version marker."
            ],
            "peek": [
                "type": "object",
                "additionalProperties": false,
                "description": "Optional configuration for the opt-in hold-modifier peek overlay and Spotlight Search HUD (hotkeyd peek).",
                "properties": [
                    "enabled": [
                        "type": "boolean",
                        "default": false,
                        "description": "Master switch for hold-modifier peek and optional overlay/search toggle hotkeys (off by default; opt in via `hotkeyd peek enable`)."
                    ],
                    "triggers": [
                        "type": "array",
                        "items": ["type": "string"],
                        "default": ["fn"],
                        "description": "Modifier tokens whose sustained hold opens the full peek overlay (default: fn; capsLock activates only when at least one capsLock shortcut is enabled)."
                    ],
                    "delayMs": [
                        "type": "integer",
                        "minimum": 300,
                        "maximum": 2000,
                        "default": 450,
                        "description": "Hold duration in milliseconds before the peek overlay appears (300..2000; strictly above the 250ms tap window)."
                    ],
                    "toggle": [
                        "type": ["string", "null"],
                        "description": "Optional key combo, two-step sequence (e.g. fn > / or fn:/), or bare modifier double-tap that toggles the pinned peek overlay hands-free."
                    ],
                    "searchToggle": [
                        "type": ["string", "null"],
                        "description": "Optional key combo, two-step sequence (e.g. fn > s or fn:s), or bare modifier double-tap that toggles the Spotlight Search HUD directly."
                    ],
                    "dimUnmatched": [
                        "type": "boolean",
                        "default": true,
                        "description": "When true (default), dims unmatched shortcuts when spotlighting a held modifier while pinned; set false for softer contrast."
                    ],
                    "showDisabled": [
                        "type": "boolean",
                        "default": false,
                        "description": "When true, disabled shortcuts are included in the peek overlay and Spotlight Search HUD."
                    ]
                ]
            ],
            "shortcuts": [
                "type": "array",
                "items": shortcutJSONSchema
            ]
        ]
    ]

    public static func canonicalSchemaTarget(_ target: String) -> String? {
        switch target.lowercased() {
        case "config", "shortcuts", "":
            return "config"
        case "shortcut", "entry":
            return "shortcut"
        default:
            return nil
        }
    }

    public static func renderJSONSchema(target: String) -> Data? {
        guard let canonical = canonicalSchemaTarget(target) else {
            return nil
        }
        let dictionary: [String: Any] = canonical == "shortcut" ? shortcutJSONSchema : configJSONSchema
        return try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
