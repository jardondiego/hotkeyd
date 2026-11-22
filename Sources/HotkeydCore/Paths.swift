import Darwin
import Foundation

public enum Paths {
    private static let overrideLock = NSLock()
    private static var _ignoreEnvironmentOverride: Bool = false

    /// Set by `hotkeyd daemon run` so an inherited `HOTKEYD_HOME` from `launchctl setenv`
    /// cannot redirect the TCC-trusted daemon's configuration or logs.
    public static var ignoreEnvironmentOverride: Bool {
        get {
            overrideLock.lock()
            defer { overrideLock.unlock() }
            return _ignoreEnvironmentOverride
        }
        set {
            overrideLock.lock()
            _ignoreEnvironmentOverride = newValue
            overrideLock.unlock()
        }
    }

    /// Resolves the current user's home directory from the system password database (`pw_dir`)
    /// rather than trusting `$HOME` from the process environment.
    public static var realHomeDirectory: URL {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        if bufferSize <= 0 {
            bufferSize = 16_384
        }
        var buffer = [CChar](repeating: 0, count: bufferSize)
        if getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result) == 0,
           let result,
           let dir = result.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Resolves the current user's login name from `getpwuid(getuid())` (`pw_name`).
    public static var realUserName: String {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        if bufferSize <= 0 {
            bufferSize = 16_384
        }
        var buffer = [CChar](repeating: 0, count: bufferSize)
        if getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result) == 0,
           let result,
           let name = result.pointee.pw_name {
            let value = String(cString: name)
            if !value.isEmpty {
                return value
            }
        }
        if let pw = getpwuid(getuid()), let name = pw.pointee.pw_name {
            let value = String(cString: name)
            if !value.isEmpty {
                return value
            }
        }
        return NSUserName()
    }

    /// Expands a leading `~` or `~/` against `realHomeDirectory` (ignoring `$HOME`).
    public static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return realHomeDirectory.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            if suffix.isEmpty {
                return realHomeDirectory.path
            }
            return realHomeDirectory.appendingPathComponent(suffix).path
        }
        return path
    }

    /// Resolves a configured working directory to an absolute path, or returns `nil` if invalid.
    public static func resolveWorkingDirectory(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            return nil
        }
        let expanded = expandTilde(trimmed)
        guard expanded.hasPrefix("/") else {
            return nil
        }
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("."), !parts.contains("..") else {
            return nil
        }
        return expanded
    }

    private static var environmentOverride: String? {
        guard !ignoreEnvironmentOverride else { return nil }
        guard let raw = getenv("HOTKEYD_HOME") else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    public static var isEnvironmentOverrideActive: Bool {
        environmentOverride != nil
    }

    /// `HOTKEYD_HOME` relocates every piece of state, which keeps tests and agent experiments
    /// away from real bindings (ignored inside `hotkeyd daemon run`).
    public static var root: URL {
        if let override = environmentOverride {
            return URL(fileURLWithPath: expandTilde(override), isDirectory: true)
        }
        return realHomeDirectory
            .appendingPathComponent("Library/Application Support/Hotkeyd", isDirectory: true)
    }

    /// The configuration deliberately lives directly in $HOME: it is the one file a human or an
    /// agent needs to find, read, diff and version. Everything incidental (logs, sockets) stays in
    /// Application Support. `HOTKEYD_HOME` moves both, which is how tests and sandboxes work.
    public static var config: URL {
        guard environmentOverride == nil else {
            return root.appendingPathComponent(".hotkeyd")
        }
        return realHomeDirectory.appendingPathComponent(".hotkeyd")
    }

    public static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public static var actionLog: URL { logs.appendingPathComponent("actions.log") }
    public static var daemonLog: URL { logs.appendingPathComponent("daemon.log") }
    public static var runtimeState: URL { root.appendingPathComponent("runtime-state.json") }
    public static var pauseState: URL { root.appendingPathComponent("pause-state.json") }
    public static var suppressAXPromptSentinel: URL { root.appendingPathComponent(".suppress-ax-prompt") }
    public static var scriptsDirectory: URL { root.appendingPathComponent("scripts", isDirectory: true) }
    public static var launchAgentPlist: URL {
        realHomeDirectory
            .appendingPathComponent("Library/LaunchAgents/io.github.jardondiego.hotkeyd.daemon.plist")
    }
    public static var installedBinary: URL {
        let localBin = realHomeDirectory.appendingPathComponent(".local/bin/hotkeyd")
        if FileManager.default.fileExists(atPath: localBin.path) {
            return localBin
        }
        let legacyBin = realHomeDirectory.appendingPathComponent("bin/hotkeyd")
        if FileManager.default.fileExists(atPath: legacyBin.path) {
            return legacyBin
        }
        return localBin
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try tightenDirectoryPermissions(at: root.path)
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try tightenDirectoryPermissions(at: logs.path)
    }

    private static func tightenDirectoryPermissions(at path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw StrictModes.StrictModesError.symlinkComponent(path)
            }
            if err == ENOTDIR {
                throw StrictModes.StrictModesError.unexpectedFileType(path)
            }
            throw StrictModes.StrictModesError.statFailed(path, String(cString: strerror(err)))
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw StrictModes.StrictModesError.statFailed(path, String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw StrictModes.StrictModesError.unexpectedFileType(path)
        }
        guard st.st_uid == getuid() else {
            throw StrictModes.StrictModesError.untrustedOwner(path, st.st_uid)
        }
        if fchmod(fd, 0o700) != 0 {
            throw StrictModes.StrictModesError.statFailed(path, String(cString: strerror(errno)))
        }
    }
}
