import AppKit
import Darwin
import Foundation

public enum InitStarterPreset: String, Codable, Sendable, CaseIterable {
    case minimal
    case empty
    case skip
}

public enum InitConfigState: Equatable, Sendable {
    case missing
    case valid(shortcutCount: Int, config: Config)
    case empty(config: Config)
    case loosePermissions(mode: mode_t)
    case symlink(target: String)
    case invalid(reason: String)

    public var kindName: String {
        switch self {
        case .missing: return "missing"
        case .valid: return "valid"
        case .empty: return "empty"
        case .loosePermissions: return "loose_permissions"
        case .symlink: return "symlink"
        case .invalid: return "invalid"
        }
    }
}

public struct InitStarterBinding: Codable, Sendable, Equatable {
    public let keys: String
    public let label: String
    public let name: String
    public let command: String
    public let summary: String
    public let source: String

    public init(
        keys: String,
        label: String,
        name: String,
        command: String,
        summary: String,
        source: String
    ) {
        self.keys = keys
        self.label = label
        self.name = name
        self.command = command
        self.summary = summary
        self.source = source
    }

    public func toShortcut() throws -> Shortcut {
        let target = try KeyTarget.parse(keys)
        return Shortcut(
            keys: target,
            tap: nil,
            doubleTap: command,
            name: name,
            enabled: true,
            passThrough: false,
            allowAccessibility: false
        )
    }
}

public struct VerificationCandidate: Codable, Sendable, Equatable {
    public let keys: String
    public let triggerDisplay: String
    public let displayName: String
    public let humanPrompt: String
    public let actionSummary: String
    public let command: String
    public let appName: String
    public let isCurrentTerminal: Bool
    public let isDoubleTap: Bool

    public init(
        keys: String,
        triggerDisplay: String,
        displayName: String,
        humanPrompt: String,
        actionSummary: String,
        command: String,
        appName: String,
        isCurrentTerminal: Bool,
        isDoubleTap: Bool
    ) {
        self.keys = keys
        self.triggerDisplay = triggerDisplay
        self.displayName = displayName
        self.humanPrompt = humanPrompt
        self.actionSummary = actionSummary
        self.command = command
        self.appName = appName
        self.isCurrentTerminal = isCurrentTerminal
        self.isDoubleTap = isDoubleTap
    }
}

public enum VerificationLogEvent: Equatable, Sendable {
    case fired(trigger: String, name: String)
    case completed(exitCode: Int, durationMs: Int)
    case timedOut(durationMs: Int)
    case dropped
}

public enum InitSupport {
    private static let browserFallbacks: [(name: String, bundleID: String)] = [
        ("Google Chrome", "com.google.Chrome"),
        ("Arc", "company.thebrowser.Browser"),
        ("Brave Browser", "com.brave.Browser"),
        ("Firefox", "org.mozilla.firefox"),
        ("Zen Browser", "app.zen-browser.zen"),
        ("Safari", "com.apple.Safari")
    ]

    private static let terminalFallbacks: [(name: String, bundleID: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("Terminal", "com.apple.Terminal")
    ]

    private static let termProgramMap: [String: (name: String, bundleID: String)] = [
        "iterm.app": ("iTerm", "com.googlecode.iterm2"),
        "iterm2": ("iTerm", "com.googlecode.iterm2"),
        "apple_terminal": ("Terminal", "com.apple.Terminal"),
        "ghostty": ("Ghostty", "com.mitchellh.ghostty"),
        "warpterminal": ("Warp", "dev.warp.Warp-Stable"),
        "wezterm": ("WezTerm", "com.github.wez.wezterm"),
        "kitty": ("kitty", "net.kovidgoyal.kitty"),
        "alacritty": ("Alacritty", "org.alacritty"),
        "vscode": ("Visual Studio Code", "com.microsoft.VSCode"),
        "cursor": ("Cursor", "com.todesktop.230313mzl4w4u92"),
        "zed": ("Zed", "dev.zed.Zed")
    ]

    // MARK: - 6-state config inspection & repair

    public static func inspectConfigState(at url: URL = Paths.config) -> InitConfigState {
        let normalizedParent = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        if !Paths.isEnvironmentOverrideActive {
            do {
                try StrictModes.verifySecurePath(normalizedParent, expectRegularFile: false)
            } catch {
                return .invalid(reason: error.localizedDescription)
            }
        }
        do {
            let dirFD = try StrictModes.openVerifiedDirectory(normalizedParent)
            close(dirFD)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }

        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT {
                return .missing
            }
            return .invalid(reason: "could not inspect \(url.path): \(String(cString: strerror(errno)))")
        }

        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            let target = readSymlinkTarget(at: url.path) ?? "(unknown target)"
            return .symlink(target: target)
        }
        if fileType != S_IFREG {
            return .invalid(reason: "\(url.path) must be a regular file")
        }
        if st.st_uid != getuid() {
            return .invalid(reason: "\(url.path) is owned by uid \(st.st_uid), expected \(getuid())")
        }
        let perms = st.st_mode & 0o777
        if (perms & 0o077) != 0 {
            return .loosePermissions(mode: perms)
        }

        do {
            let config = try Config.load(from: url)
            try config.validate()
            if config.shortcuts.isEmpty {
                return .empty(config: config)
            }
            return .valid(shortcutCount: config.shortcuts.count, config: config)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
    }

    /// Descriptor-pinned `chmod 0600` (`StrictModes` parent check + `openat(O_NOFOLLOW)` + `fchmod`)
    /// for loose regular config files.
    public static func fixLoosePermissions(at url: URL = Paths.config) throws {
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw ConfigError.insecureConfig("invalid configuration path '\(url.path)'")
        }
        let normalizedParent = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        if !Paths.isEnvironmentOverrideActive {
            try StrictModes.verifySecurePath(normalizedParent, expectRegularFile: false)
        }
        let dirFD = try StrictModes.openVerifiedDirectory(normalizedParent)
        defer { close(dirFD) }

        let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw ConfigError.insecureConfig("could not open \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw ConfigError.insecureConfig("could not stat \(url.path): \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.insecureConfig("\(url.path) is not a regular file")
        }
        guard st.st_uid == getuid() else {
            throw ConfigError.insecureConfig("\(url.path) is not owned by the current user")
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw ConfigError.insecureConfig("chmod 0600 failed on \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Reads the regular file referenced by a user-owned symlinked `~/.hotkeyd`, verifies the
    /// resolved target is a user-owned, non-group/world-writable regular file inside a trusted
    /// directory (never `/tmp`, `/var/tmp`, or group/world-writable paths), validates its JSON
    /// before modifying anything, and atomically replaces the symlink with a regular `0600` copy
    /// under `Config.withExclusiveLock` without mutating the dotfiles source file.
    public static func materializeSymlinkConfig(at url: URL = Paths.config) throws -> Config {
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw ConfigError.insecureConfig("invalid configuration path '\(url.path)'")
        }
        let normalizedParent = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        if !Paths.isEnvironmentOverrideActive {
            try StrictModes.verifySecurePath(normalizedParent, expectRegularFile: false)
        }
        let dirFD = try StrictModes.openVerifiedDirectory(normalizedParent)
        defer { close(dirFD) }

        var lst = stat()
        guard fstatat(dirFD, filename, &lst, AT_SYMLINK_NOFOLLOW) == 0,
              (lst.st_mode & S_IFMT) == S_IFLNK else {
            throw ConfigError.insecureConfig("\(url.path) is not a symlink")
        }
        guard lst.st_uid == getuid() else {
            throw ConfigError.insecureConfig("symlink \(url.path) is owned by untrusted uid \(lst.st_uid)")
        }

        let fd = openat(dirFD, filename, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw ConfigError.insecureConfig("could not read symlink target of \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw ConfigError.insecureConfig("could not stat symlink target of \(url.path): \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.insecureConfig("symlink target of \(url.path) is not a regular file")
        }
        guard st.st_uid == getuid() else {
            throw ConfigError.insecureConfig("symlink target of \(url.path) must be owned by uid \(getuid()) (found uid \(st.st_uid))")
        }
        let targetPerms = st.st_mode & 0o777
        guard (targetPerms & (S_IWGRP | S_IWOTH)) == 0 else {
            throw ConfigError.insecureConfig(
                "refusing group/world-writable symlink target (\(String(format: "%04o", targetPerms))); fix target permissions first"
            )
        }

        // Resolve the real path of the opened descriptor and verify its parent directory is
        // trusted (rejecting /tmp, /var/tmp, and group/world-writable directories).
        var realPathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &realPathBuf) == 0 else {
            throw ConfigError.insecureConfig("could not resolve canonical path of symlink target")
        }
        let resolvedTargetPath = String(cString: realPathBuf)
        let forbiddenPrefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/"]
        if forbiddenPrefixes.contains(where: { resolvedTargetPath.hasPrefix($0) }) {
            throw ConfigError.insecureConfig("refusing symlink target inside temporary directory (\(resolvedTargetPath))")
        }
        let targetParent = StrictModes.normalizeSystemVarPrefix(
            URL(fileURLWithPath: resolvedTargetPath).deletingLastPathComponent().path
        )
        if !Paths.isEnvironmentOverrideActive {
            try StrictModes.verifySecurePath(targetParent, expectRegularFile: false)
        }
        let targetParentFD = try StrictModes.openVerifiedDirectory(targetParent)
        close(targetParentFD)

        let maxBytes = 1_048_576
        guard st.st_size <= off_t(maxBytes) else {
            throw ConfigError.insecureConfig("symlink target of \(url.path) exceeds 1 MiB limit")
        }

        var data = Data()
        data.reserveCapacity(Int(max(0, st.st_size)))
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfigError.insecureConfig("could not read symlink target: \(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > maxBytes {
                throw ConfigError.insecureConfig("symlink target of \(url.path) exceeds 1 MiB limit")
            }
        }

        let config: Config
        if data.isEmpty {
            config = Config()
        } else {
            do {
                config = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                throw ConfigError.malformed(error.localizedDescription)
            }
            try config.validate()
        }

        try Config.withExclusiveLock(for: url) {
            var recheck = stat()
            guard fstatat(dirFD, filename, &recheck, AT_SYMLINK_NOFOLLOW) == 0,
                  (recheck.st_mode & S_IFMT) == S_IFLNK,
                  recheck.st_uid == getuid() else {
                throw ConfigError.insecureConfig("\(url.path) changed concurrently before materialization")
            }
            try StrictModes.atomicWrite(data, to: url, mode: 0o600)
        }
        return config
    }

    private static func readSymlinkTarget(at path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[length] = 0
        return String(cString: buffer)
    }

    // MARK: - App auto-detection & starter pack

    /// Pure environment-based detection of the terminal app running the current CLI session
    /// (also unwraps common tmux/screen parent terminal hints).
    public static func detectActiveTerminalSpec(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (name: String, bundleID: String)? {
        if let rawProgram = environment["TERM_PROGRAM"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawProgram.isEmpty {
            let lowered = rawProgram.lowercased()
            if let mapped = termProgramMap[lowered] {
                return mapped
            }
        }
        if let lcTerminal = environment["LC_TERMINAL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let mapped = termProgramMap[lcTerminal.lowercased()] {
            return mapped
        }
        if let ghostty = environment["GHOSTTY_RESOURCES_DIR"], !ghostty.isEmpty {
            return ("Ghostty", "com.mitchellh.ghostty")
        }
        if let wezterm = environment["WEZTERM_EXECUTABLE"], !wezterm.isEmpty {
            return ("WezTerm", "com.github.wez.wezterm")
        }
        if let kitty = environment["KITTY_WINDOW_ID"], !kitty.isEmpty {
            return ("kitty", "net.kovidgoyal.kitty")
        }
        if let warp = environment["WARP_IS_LOCAL_SHELL_SESSION"], !warp.isEmpty {
            return ("Warp", "dev.warp.Warp-Stable")
        }
        return nil
    }

    public static func detectDefaultBrowser() -> (name: String, source: String) {
        if let probeURL = URL(string: "https://example.com"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL),
           let candidate = safeAppName(from: appURL) {
            return (candidate, "default_browser")
        }
        for entry in browserFallbacks {
            if isInstalledApp(name: entry.name, bundleID: entry.bundleID) {
                return (entry.name, "installed")
            }
        }
        return ("Safari", "fallback")
    }

    public static func detectPreferredTerminal(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (name: String, source: String) {
        if let active = detectActiveTerminalSpec(environment: environment),
           isInstalledApp(name: active.name, bundleID: active.bundleID) {
            return (active.name, "term_program")
        }
        for entry in terminalFallbacks {
            if isInstalledApp(name: entry.name, bundleID: entry.bundleID) {
                return (entry.name, "installed")
            }
        }
        return ("Terminal", "fallback")
    }

    public static func buildMinimalStarters(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [InitStarterBinding] {
        let browser = detectDefaultBrowser()
        let terminal = detectPreferredTerminal(environment: environment)
        let browserCommand = "open -a \(Action.shellArgument(browser.name))"
        let terminalCommand = "open -a \(Action.shellArgument(terminal.name))"

        return [
            InitStarterBinding(
                keys: "lcmd",
                label: "double-tap Left Command",
                name: browser.name,
                command: browserCommand,
                summary: browser.name,
                source: browser.source
            ),
            InitStarterBinding(
                keys: "lopt",
                label: "double-tap Left Option",
                name: terminal.name,
                command: terminalCommand,
                summary: terminal.name,
                source: terminal.source
            ),
            InitStarterBinding(
                keys: "rcmd",
                label: "double-tap Right Command",
                name: "Home",
                command: "open ~",
                summary: "Home folder (~)",
                source: "builtin"
            )
        ]
    }

    private static func isInstalledApp(name: String, bundleID: String) -> Bool {
        if ShellRunner.resolveApplicationURL(for: name) != nil {
            return true
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           safeAppName(from: url) != nil {
            return true
        }
        return false
    }

    private static func safeAppName(from appURL: URL) -> String? {
        let path = appURL.standardizedFileURL.path
        guard path.hasSuffix(".app") else { return nil }
        let home = Paths.realHomeDirectory.path
        let forbiddenPrefixes = [
            "/Volumes/",
            "/tmp/",
            "/private/tmp/",
            "\(home)/Downloads/",
            "\(home)/.Trash/"
        ]
        if path.contains("/.build/") || forbiddenPrefixes.contains(where: { path.hasPrefix($0) }) {
            return nil
        }
        let stem = appURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return nil }
        let command = "open -a \(Action.shellArgument(stem))"
        guard case .app(let target, let arguments) = Action.migratedFromShellCommand(command),
              !target.isEmpty,
              arguments.isEmpty else {
            return nil
        }
        return stem
    }

    // MARK: - Safe Step 4 Verification Candidate Selection

    /// Picks a strictly non-destructive native `.app` shortcut (zero arguments, no shell scripts,
    /// no URLs, no directory launches, no `allowAccessibility`, no `cwd`) to verify live event-tap
    /// firing without risking Lock Screen, Sleep, or arbitrary script execution on existing dotfiles.
    public static func selectSafeVerificationCandidate(
        from config: Config,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        capsLockRemapped: Bool = false
    ) -> VerificationCandidate? {
        let activeTerminal = detectActiveTerminalSpec(environment: environment)
        var candidates: [(rank: Int, candidate: VerificationCandidate)] = []

        for shortcut in config.shortcuts {
            guard shortcut.enabled,
                  !shortcut.allowAccessibility,
                  (shortcut.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
                continue
            }
            if shortcut.keys.usesCapsLock && !capsLockRemapped {
                continue
            }

            let slots: [(isDoubleTap: Bool, command: String)] = [
                shortcut.doubleTap.map { (true, $0) },
                shortcut.tap.map { (false, $0) }
            ].compactMap { $0 }

            for slot in slots {
                guard !SelectionReader.commandUsesSelectedText(slot.command),
                      case .app(let target, let arguments) = Action.migratedFromShellCommand(slot.command),
                      arguments.isEmpty else {
                    continue
                }
                // On paired combos (`tap` + `doubleTap`), never suggest testing `doubleTap` if the
                // paired `tap` slot could execute a non-benign action on a slow or single tap.
                if case .combo = shortcut.keys, slot.isDoubleTap, let pairedTap = shortcut.tap {
                    guard !SelectionReader.commandUsesSelectedText(pairedTap),
                          case .app(_, let pairedArgs) = Action.migratedFromShellCommand(pairedTap),
                          pairedArgs.isEmpty else {
                        continue
                    }
                }

                let appDisplay = target.hasSuffix(".app")
                    ? URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
                    : target
                let matchesTerminal = isMatchingTerminal(target: appDisplay, activeTerminal: activeTerminal)
                let triggerDisplay = triggerDisplayFor(keys: shortcut.keys, isDoubleTap: slot.isDoubleTap)
                let humanPrompt = humanPromptFor(keys: shortcut.keys, isDoubleTap: slot.isDoubleTap)
                let isBareModifier: Bool
                if case .modifier = shortcut.keys {
                    isBareModifier = true
                } else {
                    isBareModifier = false
                }

                let rank: Int
                if matchesTerminal && isBareModifier {
                    rank = 0
                } else if matchesTerminal {
                    rank = 1
                } else if isBareModifier {
                    rank = 2
                } else {
                    rank = 3
                }

                let candidate = VerificationCandidate(
                    keys: shortcut.keys.canonical,
                    triggerDisplay: triggerDisplay,
                    displayName: shortcut.displayName,
                    humanPrompt: humanPrompt,
                    actionSummary: "activate \(appDisplay)",
                    command: slot.command,
                    appName: appDisplay,
                    isCurrentTerminal: matchesTerminal,
                    isDoubleTap: slot.isDoubleTap
                )
                candidates.append((rank, candidate))
            }
        }

        return candidates.min(by: { $0.rank < $1.rank })?.candidate
    }

    private static func isMatchingTerminal(
        target: String,
        activeTerminal: (name: String, bundleID: String)?
    ) -> Bool {
        guard let activeTerminal else { return false }
        let lowered = target.lowercased()
        if lowered == activeTerminal.name.lowercased() || lowered == activeTerminal.bundleID.lowercased() {
            return true
        }
        // Handle common iTerm / iTerm2 naming alias.
        if activeTerminal.name == "iTerm" && (lowered == "iterm2" || lowered == "iterm.app") {
            return true
        }
        return false
    }

    private static func triggerDisplayFor(keys: KeyTarget, isDoubleTap: Bool) -> String {
        switch keys {
        case .modifier(let modifier):
            return Trigger.doubleTap(modifier: modifier, windowMilliseconds: nil).display
        case .combo(let combo):
            return isDoubleTap
                ? Trigger.doubleTapKeys(combo, windowMilliseconds: nil).display
                : Trigger.keys(combo).display
        case .sequence(let sequence):
            return Trigger.sequence(sequence, maxSequenceDelayMilliseconds: nil).display
        }
    }

    private static func humanPromptFor(keys: KeyTarget, isDoubleTap: Bool) -> String {
        switch keys {
        case .modifier(let modifier):
            return "Double-tap \(friendlyModifierName(modifier))"
        case .combo(let combo):
            return isDoubleTap
                ? "Double-tap \(combo.canonical)"
                : "Press \(combo.canonical)"
        case .sequence(let sequence):
            return "Tap \(friendlyModifierName(sequence.leader)), then press \(KeyCodes.name(for: sequence.keyCode))"
        }
    }

    private static func friendlyModifierName(_ modifier: Modifier) -> String {
        switch (modifier.family, modifier.side) {
        case (.command, .left): return "Left Command"
        case (.command, .right): return "Right Command"
        case (.command, nil): return "Command"
        case (.option, .left): return "Left Option"
        case (.option, .right): return "Right Option"
        case (.option, nil): return "Option"
        case (.control, .left): return "Left Control"
        case (.control, .right): return "Right Control"
        case (.control, nil): return "Control"
        case (.shift, .left): return "Left Shift"
        case (.shift, .right): return "Right Shift"
        case (.shift, nil): return "Shift"
        case (.capsLock, _): return "Caps Lock"
        case (.fn, _): return "Fn"
        }
    }

    // MARK: - Two-stage verification log parsers

    public static func parseDaemonLogLine(
        _ line: String,
        candidate: VerificationCandidate
    ) -> VerificationLogEvent? {
        let marker = " daemon fire \(candidate.triggerDisplay) -> "
        guard let range = line.range(of: marker) else { return nil }
        let loggedName = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = singleLine(candidate.displayName)
        guard loggedName == expected || loggedName.hasPrefix(expected) else { return nil }
        return .fired(trigger: candidate.triggerDisplay, name: loggedName)
    }

    public static func parseActionLogLine(
        _ line: String,
        candidate: VerificationCandidate
    ) -> VerificationLogEvent? {
        let expected = singleLine(candidate.displayName)
        let marker = " action shortcut=\(expected) "
        guard let range = line.range(of: marker) else { return nil }
        let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("stderr=") {
            return nil
        }
        if rest.hasPrefix("dropped") {
            return .dropped
        }
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return nil }
        let outcome = String(tokens[0])
        let msToken = String(tokens[1])
        let durationMs: Int
        if msToken.hasSuffix("ms"), let parsed = Int(msToken.dropLast(2)) {
            durationMs = parsed
        } else {
            durationMs = 0
        }
        if outcome == "timeout" {
            return .timedOut(durationMs: durationMs)
        }
        if outcome.hasPrefix("exit="), let code = Int(outcome.dropFirst("exit=".count)) {
            return .completed(exitCode: code, durationMs: durationMs)
        }
        return nil
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Preflight error classification

    public static func classifyExecutableTrustError(
        _ error: Error,
        binaryPath: String,
        allowAdhoc: Bool
    ) -> (summary: String, fix: String) {
        if let strictError = error as? StrictModes.StrictModesError {
            switch strictError {
            case .symlinkComponent:
                return (
                    "binary path passes through a symlink (\(binaryPath))",
                    "LaunchAgent requires a real non-symlink path; run `./scripts/build.sh` to install at ~/.local/bin/hotkeyd or invoke the real binary path directly"
                )
            case .insecurePermissions(let path, let mode):
                return (
                    "insecure permissions (\(String(format: "%04o", mode))) on \(path)",
                    "tighten group/world write bits (chmod go-w '\(path)')"
                )
            default:
                return (
                    strictError.localizedDescription,
                    "install hotkeyd to a user-owned, non-symlink path such as ~/.local/bin/hotkeyd"
                )
            }
        }
        if let trustError = error as? CodeTrust.TrustError {
            switch trustError {
            case .forbiddenBuildOrTempPath:
                return (
                    "running from a temporary or build directory (\(binaryPath))",
                    "install hotkeyd first via `./scripts/build.sh` (installs to ~/.local/bin/hotkeyd), then run `hotkeyd init`"
                )
            case .missingHardenedRuntime, .missingOrInvalidSignature:
                return (
                    trustError.localizedDescription,
                    "run `./scripts/setup-signing.sh && ./scripts/build.sh` to sign with Hardened Runtime and install to ~/.local/bin/hotkeyd"
                )
            case .adhocSignatureDisallowed, .unanchoredDesignatedRequirement:
                let suffix = allowAdhoc
                    ? ""
                    : " (or pass `--allow-adhoc` only for a Hardened-Runtime ad-hoc build)"
                return (
                    trustError.localizedDescription,
                    "run `./scripts/setup-signing.sh && ./scripts/build.sh` to sign with a local certificate\(suffix)"
                )
            default:
                return (
                    trustError.localizedDescription,
                    "run `./scripts/setup-signing.sh && ./scripts/build.sh` from the hotkeyd repository"
                )
            }
        }
        return (
            error.localizedDescription,
            "run `./scripts/setup-signing.sh && ./scripts/build.sh` from the hotkeyd repository"
        )
    }
}
