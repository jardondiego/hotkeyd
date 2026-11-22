import Darwin
import Foundation

/// Minimal, thread-safe, non-blocking logging. Formatting and file appends run on a dedicated
/// serial `.utility` queue so the `.userInteractive` event tap thread never contends on a lock or
/// blocks on disk I/O.
public enum Log {
    public static let maxLogFileSizeBytes: off_t = 5 * 1_048_576

    private static let queue = DispatchQueue(label: "io.github.jardondiego.hotkeyd.log", qos: .utility)
    private static var daemonLinesSinceRotationCheck = 0
    /// When running interactively on a TTY, echo action logs to stdout in addition to `actions.log`.
    /// Under `launchd` (`isatty == 0`), stdout IS `daemon.log`, so echoing would duplicate every
    /// action entry across both `daemon.log` and `actions.log`.
    private static let echoActionsToStdout: Bool = isatty(STDOUT_FILENO) == 1
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Strips ASCII/C1 control characters, ANSI/OSC escape sequences, Unicode line separators, and
    /// Bidi override/isolate controls so log entries stay strictly single-line and terminal-safe.
    public static func sanitizeMessage(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x0D || v == 0x09 {
                scalars.append(" ")
            } else if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F)
                || v == 0x061C || v == 0x200E || v == 0x200F
                || v == 0x2028 || v == 0x2029
                || (v >= 0x202A && v <= 0x202E)
                || (v >= 0x2066 && v <= 0x2069) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    public static func daemon(_ message: String) {
        let timestamp = Date()
        let cleaned = sanitizeMessage(message)
        queue.async {
            daemonLinesSinceRotationCheck += 1
            if daemonLinesSinceRotationCheck >= 256 {
                daemonLinesSinceRotationCheck = 0
                rotateDaemonLogFileIfNeeded()
            }
            let line = "\(formatter.string(from: timestamp)) daemon \(cleaned)"
            print(line)
            fflush(stdout)
        }
    }

    public static func action(_ message: String) {
        let timestamp = Date()
        let cleaned = sanitizeMessage(message)
        queue.async {
            let line = "\(formatter.string(from: timestamp)) action \(cleaned)"
            if echoActionsToStdout {
                print(line)
                fflush(stdout)
            }
            append(line, to: Paths.actionLog)
        }
    }

    /// Rotates `Paths.daemonLog` to `daemon.log.1` when it reaches `maxLogFileSizeBytes` and, if
    /// `stdout`/`stderr` currently point to the rotated inode (as under `launchd`), atomically
    /// re-binds them to the fresh `0600` `daemon.log`.
    public static func rotateDaemonLogIfNeeded() {
        queue.sync {
            rotateDaemonLogFileIfNeeded()
        }
    }

    private static func rotateDaemonLogFileIfNeeded() {
        let url = Paths.daemonLog
        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(
            StrictModes.normalizeSystemVarPrefix(directory.path)
        ) else {
            return
        }
        defer { close(dirFD) }

        var fileStat = stat()
        guard fstatat(dirFD, filename, &fileStat, AT_SYMLINK_NOFOLLOW) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == getuid(),
              fileStat.st_size >= maxLogFileSizeBytes else {
            return
        }

        let rotatedName = "\(filename).1"
        _ = unlinkat(dirFD, rotatedName, 0)
        guard renameat(dirFD, filename, dirFD, rotatedName) == 0 else { return }

        let newFD = openat(dirFD, filename, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard newFD >= 0 else { return }
        _ = fchmod(newFD, 0o600)

        var outStat = stat()
        if fstat(STDOUT_FILENO, &outStat) == 0,
           outStat.st_dev == fileStat.st_dev,
           outStat.st_ino == fileStat.st_ino {
            fflush(stdout)
            _ = dup2(newFD, STDOUT_FILENO)
        }
        var errStat = stat()
        if fstat(STDERR_FILENO, &errStat) == 0,
           errStat.st_dev == fileStat.st_dev,
           errStat.st_ino == fileStat.st_ino {
            fflush(stderr)
            _ = dup2(newFD, STDERR_FILENO)
        }
        close(newFD)
    }

    /// Synchronously drains all pending log writes before process exit.
    public static func flush() {
        queue.sync {}
    }

    /// Pre-creates or verifies `url` as a `0600` non-symlink regular file owned by `getuid()` inside
    /// a verified `0700` parent directory (used for `daemon.log` before `launchd` opens stdout/stderr).
    public static func prepareLogFile(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let dirFD = try StrictModes.openVerifiedDirectory(directory.path)
        defer { close(dirFD) }

        let fd = openat(dirFD, filename, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw StrictModes.StrictModesError.symlinkComponent(url.path)
            }
            throw StrictModes.StrictModesError.statFailed(url.path, String(cString: strerror(err)))
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw StrictModes.StrictModesError.statFailed(url.path, String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw StrictModes.StrictModesError.unexpectedFileType(url.path)
        }
        guard st.st_uid == getuid() else {
            throw StrictModes.StrictModesError.untrustedOwner(url.path, st.st_uid)
        }
        if fchmod(fd, 0o600) != 0 {
            throw StrictModes.StrictModesError.statFailed(url.path, String(cString: strerror(errno)))
        }
    }

    private static func append(_ line: String, to url: URL) {
        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return
        }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(directory.path) else {
            return
        }
        defer { close(dirFD) }

        var fd = openat(dirFD, filename, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid() else {
            close(fd)
            return
        }
        _ = fchmod(fd, 0o600)

        if st.st_size >= maxLogFileSizeBytes {
            close(fd)
            let rotatedName = "\(filename).1"
            _ = unlinkat(dirFD, rotatedName, 0)
            _ = renameat(dirFD, filename, dirFD, rotatedName)
            fd = openat(dirFD, filename, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            _ = fchmod(fd, 0o600)
        }
        defer { close(fd) }

        let payload = Data((line + "\n").utf8)
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    break
                }
                offset += written
            }
        }
    }
}
