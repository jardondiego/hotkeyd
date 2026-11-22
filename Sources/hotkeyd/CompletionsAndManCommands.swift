import Darwin
import Foundation
import HotkeydCore

struct CompletionsPayload: Encodable {
    let shell: String
    let installPath: String
    let installed: Bool
    let activationHint: String
    let script: String
}

struct ManPagePayload: Encodable {
    let page: String
    let section: String
    let installPath: String
    let installed: Bool
    let content: String
}

func commandCompletions(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["install", "json", "help"],
        positionals: 1
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["completions"])
        return
    }
    guard let rawShell = parsed.positionals.first else {
        throw CLIError(
            message: "completions requires a shell argument (zsh, bash, or fish)",
            code: 2,
            hint: "example: hotkeyd completions zsh --install"
        )
    }
    guard let shell = CompletionShell(rawValue: rawShell.lowercased()) else {
        throw CLIError(
            message: "unsupported shell '\(rawShell)' (expected zsh, bash, or fish)",
            code: 2,
            hint: "run `hotkeyd help completions` for supported shells"
        )
    }

    let script = ShellCompletions.generateScript(for: shell, version: version)
    let installURL = ShellCompletions.defaultInstallURL(for: shell)
    let hint = ShellCompletions.activationHint(for: shell, installURL: installURL)
    let shouldInstall = parsed.switches.contains("install")

    if shouldInstall {
        do {
            try StrictModes.ensureSecureDirectory(
                at: installURL.deletingLastPathComponent(),
                mode: 0o755
            )
            try StrictModes.atomicWrite(Data(script.utf8), to: installURL, mode: 0o644)
        } catch {
            throw CLIError(
                message: "could not install \(shell.rawValue) completions to \(installURL.path): \(error.localizedDescription)",
                code: 7,
                kind: "config_io",
                hint: "you can also print the script with `hotkeyd completions \(shell.rawValue)`"
            )
        }
    }

    if wantsJSON(parsed) {
        try emitJSON(
            "completions",
            CompletionsPayload(
                shell: shell.rawValue,
                installPath: installURL.path,
                installed: shouldInstall,
                activationHint: hint,
                script: script
            )
        )
        return
    }

    if shouldInstall {
        print("✓ Installed \(shell.rawValue) completions: \(installURL.path)")
        print("  \(hint)")
    } else {
        print(script, terminator: "")
    }
}

func commandMan(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["install", "json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["man"])
        return
    }

    let content = ManPageGenerator.generate(
        version: version,
        configPath: Paths.config.path,
        logsPath: Paths.logs.path,
        launchAgentPath: Paths.launchAgentPlist.path
    )
    let installURL = ManPageGenerator.defaultInstallURL()
    let shouldInstall = parsed.switches.contains("install")

    if shouldInstall {
        do {
            try StrictModes.ensureSecureDirectory(
                at: installURL.deletingLastPathComponent(),
                mode: 0o755
            )
            try StrictModes.atomicWrite(Data(content.utf8), to: installURL, mode: 0o644)
        } catch {
            throw CLIError(
                message: "could not install man page to \(installURL.path): \(error.localizedDescription)",
                code: 7,
                kind: "config_io",
                hint: "you can also pipe `hotkeyd man | mandoc | less`"
            )
        }
    }

    if wantsJSON(parsed) {
        try emitJSON(
            "man",
            ManPagePayload(
                page: "hotkeyd",
                section: "1",
                installPath: installURL.path,
                installed: shouldInstall,
                content: content
            )
        )
        return
    }

    if shouldInstall {
        print("✓ Installed manual page: \(installURL.path)")
        print("  Run `man hotkeyd` to view it (macOS discovers ~/.local/share/man automatically when ~/.local/bin is on PATH).")
    } else {
        print(content, terminator: "")
    }
}

/// Internal tab-completion plumbing invoked by generated zsh/bash/fish scripts.
/// Always fails silently (exit 0, empty stdout/stderr) if `~/.hotkeyd` is absent or unreadable so
/// interactive tab-completion never corrupts the user's shell prompt.
func commandInternalComplete(_ arguments: [String]) throws {
    guard let kind = arguments.first?.lowercased() else { return }
    let rest = Array(arguments.dropFirst())
    let plain = rest.contains("--plain")
    let enabledOnly = rest.contains("--enabled")
    let disabledOnly = rest.contains("--disabled")

    switch kind {
    case "shortcuts":
        guard let config = try? Config.load(from: Paths.config) else {
            return
        }
        let filter: ShortcutCompletionFilter
        if enabledOnly && !disabledOnly {
            filter = .enabledOnly
        } else if disabledOnly && !enabledOnly {
            filter = .disabledOnly
        } else {
            filter = .all
        }
        let candidates = ShellCompletions.shortcutCandidates(from: config, filter: filter)
        let output = ShellCompletions.formatCandidates(candidates, plain: plain)
        if !output.isEmpty {
            print(output, terminator: "")
        }

    case "keys":
        let output = ShellCompletions.formatCandidates(ShellCompletions.keyCandidates(), plain: plain)
        if !output.isEmpty {
            print(output, terminator: "")
        }

    default:
        return
    }
}
