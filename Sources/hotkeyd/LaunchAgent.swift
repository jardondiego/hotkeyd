import Darwin
import Foundation
import HotkeydCore

enum LaunchAgent {
    static let label = "io.github.jardondiego.hotkeyd.daemon"

    static var domain: String { "gui/\(getuid())" }
    static var plistPath: String { Paths.launchAgentPlist.path }

    static func isLoaded() -> Bool {
        tool("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    static func pid() -> Int? {
        let result = tool("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let raw = String(line)
            guard raw.hasPrefix("\tpid = ") || raw.hasPrefix("pid = ") else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let parsed = Int(trimmed.dropFirst("pid = ".count)),
               parsed > 1,
               parsed <= Int(pid_t.max) {
                return parsed
            }
        }
        return nil
    }

    static func install(
        binaryPath: String,
        allowAdhoc: Bool = false,
        suppressAXPrompt: Bool = false
    ) throws {
        guard !Paths.isEnvironmentOverrideActive else {
            throw LaunchAgentError.environmentOverrideDisallowed
        }
        try StrictModes.verifySecurePath(binaryPath, expectRegularFile: true)
        _ = try CodeTrust.verify(binaryPath: binaryPath, allowAdhoc: allowAdhoc)
        try Paths.ensureDirectories()
        try Log.prepareLogFile(Paths.daemonLog)
        let directory = Paths.launchAgentPlist.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try StrictModes.verifySecurePath(directory.path, expectRegularFile: false)

        var programArguments = [binaryPath, "daemon", "run"]
        if allowAdhoc {
            programArguments.append("--allow-adhoc")
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
            "UMask": 63,
            "StandardOutPath": Paths.daemonLog.path,
            "StandardErrorPath": Paths.daemonLog.path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try StrictModes.atomicWrite(data, to: Paths.launchAgentPlist, mode: 0o600)

        let wasLoaded = isLoaded()
        _ = tool("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if wasLoaded {
            // Wait briefly for the previous daemon to finish SIGTERM cleanup and release
            // daemon.lock so the freshly bootstrapped process does not hit lock contention.
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline && isLoaded() {
                usleep(50_000)
            }
        }
        if suppressAXPrompt {
            try? RuntimeState.writeSuppressAXPromptSentinel(to: Paths.suppressAXPromptSentinel)
        }
        let bootstrap = tool("/bin/launchctl", ["bootstrap", domain, plistPath])
        guard bootstrap.status == 0 else {
            throw LaunchAgentError.bootstrapFailed(bootstrap.output)
        }
        // `RunAtLoad: true` already spawns the daemon; wait briefly for its PID and only
        // kickstart (without `-k`) if launchd has not spawned it yet.
        let spawnDeadline = Date().addingTimeInterval(0.5)
        while Date() < spawnDeadline && pid() == nil {
            usleep(50_000)
        }
        if pid() == nil {
            _ = tool("/bin/launchctl", ["kickstart", "\(domain)/\(label)"])
        }
    }

    static func uninstall() throws {
        guard !Paths.isEnvironmentOverrideActive else {
            throw LaunchAgentError.environmentOverrideDisallowed
        }
        _ = tool("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if case .enabled = CapsLock.state() {
            try? CapsLock.disable()
        }
        if Darwin.unlink(plistPath) != 0 && errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func restart() throws {
        guard !Paths.isEnvironmentOverrideActive else {
            throw LaunchAgentError.environmentOverrideDisallowed
        }
        guard isLoaded() else {
            throw LaunchAgentError.notInstalled
        }
        let result = tool("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"])
        guard result.status == 0 else {
            throw LaunchAgentError.restartFailed(result.output)
        }
    }

    private static func verifyAndSignalDaemon(signal: String, actionName: String) throws -> Int {
        guard !Paths.isEnvironmentOverrideActive else {
            throw LaunchAgentError.environmentOverrideDisallowed
        }
        guard isLoaded() else {
            throw LaunchAgentError.notInstalled
        }
        guard let runningPID = pid() else {
            throw LaunchAgentError.notRunning
        }
        let expectedPath = installedBinaryPath()
        let allowAdhoc = installedAllowsAdhoc()
        do {
            _ = try CodeTrust.verifyRunningProcess(
                pid: pid_t(runningPID),
                expectedBinaryPath: expectedPath,
                allowAdhoc: allowAdhoc
            )
        } catch {
            let detail = "running daemon failed CodeTrust verification: \(error.localizedDescription)"
            if signal == "SIGHUP" {
                throw LaunchAgentError.reloadFailed(detail)
            }
            throw LaunchAgentError.signalFailed(action: actionName, detail: detail)
        }
        let result = tool("/bin/launchctl", ["kill", signal, "\(domain)/\(label)"])
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if signal == "SIGHUP" {
                throw LaunchAgentError.reloadFailed(detail)
            }
            throw LaunchAgentError.signalFailed(action: actionName, detail: detail)
        }
        return runningPID
    }

    static func reload() throws -> Int {
        try verifyAndSignalDaemon(signal: "SIGHUP", actionName: "reload")
    }

    static func togglePeek() throws -> Int {
        try verifyAndSignalDaemon(signal: "SIGUSR1", actionName: "toggle peek overlay")
    }

    static func togglePeekSearch() throws -> Int {
        try verifyAndSignalDaemon(signal: "SIGUSR2", actionName: "toggle peek search HUD")
    }
}

struct ToolResult {
    let status: Int32
    let output: String
}

@discardableResult
func tool(_ path: String, _ arguments: [String]) -> ToolResult {
    let result = ShellRunner.runSystemTool(
        executablePath: path,
        arguments: [path] + arguments,
        timeoutMilliseconds: 5_000
    )
    let combined: String
    if result.stderr.isEmpty {
        combined = result.stdout
    } else if result.stdout.isEmpty {
        combined = result.stderr
    } else {
        combined = result.stdout + "\n" + result.stderr
    }
    return ToolResult(
        status: result.timedOut ? -1 : result.exitCode,
        output: combined
    )
}

enum LaunchAgentError: LocalizedError {
    case notInstalled
    case notRunning
    case bootstrapFailed(String)
    case restartFailed(String)
    case reloadFailed(String)
    case signalFailed(action: String, detail: String)
    case environmentOverrideDisallowed

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "the daemon is not installed; run `hotkeyd daemon install`"
        case .notRunning:
            return "the daemon is installed but not currently running; run `hotkeyd daemon start`"
        case .bootstrapFailed(let output):
            return "launchctl bootstrap failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .restartFailed(let output):
            return "launchctl restart failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .reloadFailed(let detail):
            return "could not signal daemon to reload: \(detail)"
        case .signalFailed(let action, let detail):
            return "could not signal daemon to \(action): \(detail)"
        case .environmentOverrideDisallowed:
            return "refusing to manage the live LaunchAgent while HOTKEYD_HOME is set"
        }
    }
}

extension LaunchAgent {
    enum PlistInspection {
        case missing
        case valid([String])
        case insecure(String)
    }

    /// Inspects `io.github.jardondiego.hotkeyd.daemon.plist` via verified ancestor/parent directory (`O_NOFOLLOW`),
    /// `0600` mode check, ownership check, and strict `ProgramArguments` shape validation.
    static func inspectInstalledPlist(at url: URL = Paths.launchAgentPlist) -> PlistInspection {
        let filename = url.lastPathComponent
        let directory = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return .insecure("invalid LaunchAgent plist path '\(url.path)'")
        }

        // Distinguish missing plist cleanly before StrictModes errors when ~/Library/LaunchAgents
        // doesn't exist yet.
        var preStat = stat()
        if lstat(url.path, &preStat) != 0 && errno == ENOENT {
            return .missing
        }

        if !Paths.isEnvironmentOverrideActive {
            do {
                try StrictModes.verifySecurePath(directory, expectRegularFile: false)
            } catch {
                return .insecure(error.localizedDescription)
            }
        }
        let dirFD: Int32
        do {
            dirFD = try StrictModes.openVerifiedDirectory(directory)
        } catch {
            return .insecure(error.localizedDescription)
        }
        defer { close(dirFD) }

        let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return .missing }
            if err == ELOOP {
                return .insecure("LaunchAgent plist '\(url.path)' must not be a symlink")
            }
            return .insecure("could not open LaunchAgent plist '\(url.path)': \(String(cString: strerror(err)))")
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return .insecure("could not stat LaunchAgent plist '\(url.path)'")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .insecure("LaunchAgent plist '\(url.path)' must be a regular file")
        }
        guard st.st_uid == getuid() else {
            return .insecure("LaunchAgent plist '\(url.path)' is not owned by uid \(getuid())")
        }
        let perms = st.st_mode & 0o777
        guard (perms & 0o077) == 0 else {
            return .insecure("LaunchAgent plist '\(url.path)' has insecure permissions \(String(format: "%04o", perms)) (expected 0600)")
        }
        guard st.st_size > 0, st.st_size <= 65_536 else {
            return .insecure("LaunchAgent plist '\(url.path)' has invalid size (\(st.st_size) bytes)")
        }

        let size = Int(st.st_size)
        var buffer = Data(count: size)
        let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            var total = 0
            while total < size {
                let n = Darwin.read(fd, base.advanced(by: total), size - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard bytesRead == size else {
            return .insecure("could not read LaunchAgent plist '\(url.path)'")
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: buffer, format: nil),
            let dictionary = plist as? [String: Any],
            let arguments = dictionary["ProgramArguments"] as? [String],
            arguments.count >= 3,
            arguments[0].hasPrefix("/"),
            arguments[1] == "daemon",
            arguments[2] == "run"
        else {
            return .insecure("LaunchAgent plist '\(url.path)' has unexpected ProgramArguments")
        }
        return .valid(arguments)
    }

    /// Parses `ProgramArguments` only from a verified `0600` user-owned `O_NOFOLLOW` plist.
    static func installedProgramArguments() -> [String]? {
        guard case .valid(let arguments) = inspectInstalledPlist() else {
            return nil
        }
        return arguments
    }

    /// The binary the LaunchAgent actually runs, so diagnostics describe the daemon rather than
    /// whichever copy of the CLI happens to be in the caller's hand.
    static func installedBinaryPath() -> String? {
        installedProgramArguments()?.first
    }

    /// Returns true iff a verified `0600` LaunchAgent plist explicitly opts into `--allow-adhoc`.
    static func installedAllowsAdhoc() -> Bool {
        guard let arguments = installedProgramArguments() else { return false }
        return arguments.dropFirst(3).contains("--allow-adhoc")
    }
}
