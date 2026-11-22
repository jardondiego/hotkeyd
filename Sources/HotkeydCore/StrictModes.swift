import Darwin
import Foundation

/// OpenSSH-style `StrictModes` path, ownership, and permission verifier plus atomic file writer.
public enum StrictModes {
    public enum StrictModesError: LocalizedError, Equatable {
        case notAbsolutePath(String)
        case dotTraversalComponent(String)
        case statFailed(String, String)
        case symlinkComponent(String)
        case untrustedOwner(String, uid_t)
        case insecurePermissions(String, mode_t)
        case unexpectedFileType(String)
        case atomicWriteFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .notAbsolutePath(let path):
                return "path '\(path)' is not absolute"
            case .dotTraversalComponent(let path):
                return "path '\(path)' must not contain '.' or '..' traversal components"
            case .statFailed(let path, let reason):
                return "could not stat '\(path)': \(reason)"
            case .symlinkComponent(let path):
                return "refusing symlink component '\(path)'; copy a regular file (e.g. `install -m 0600`) instead of symlinking"
            case .untrustedOwner(let path, let uid):
                return "path '\(path)' is owned by untrusted uid \(uid) (expected \(getuid()) or 0)"
            case .insecurePermissions(let path, let mode):
                return String(
                    format: "path '%@' has group/world-writable permissions %04o; fix with `chmod go-w '%@'`",
                    path,
                    UInt32(mode),
                    path
                )
            case .unexpectedFileType(let path):
                return "path '\(path)' does not have the expected file type"
            case .atomicWriteFailed(let path, let reason):
                return "atomic write to '\(path)' failed: \(reason)"
            }
        }
    }

    /// Walks every path component from `/` to `path` via `lstat(2)`:
    /// - Rejects `.` / `..` traversal segments and NUL bytes
    /// - Rejects any symlink (`S_IFLNK`)
    /// - Requires `st_uid == getuid() || st_uid == 0`
    /// - Rejects group/world-writable permissions (`S_IWGRP | S_IWOTH`)
    /// - Requires ancestor components to be directories (`S_IFDIR`) and the final component to be
    ///   a regular file (`expectRegularFile == true`) or directory (`expectRegularFile == false`).
    public static func verifySecurePath(_ path: String, expectRegularFile: Bool = false) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw StrictModesError.notAbsolutePath(path)
        }

        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in parts where part == "." || part == ".." {
            throw StrictModesError.dotTraversalComponent(path)
        }
        var prefixes: [String] = ["/"]
        var current = ""
        for part in parts {
            current += "/" + part
            prefixes.append(current)
        }

        let currentUID = getuid()
        for (index, prefix) in prefixes.enumerated() {
            var st = stat()
            guard lstat(prefix, &st) == 0 else {
                throw StrictModesError.statFailed(prefix, String(cString: strerror(errno)))
            }
            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw StrictModesError.symlinkComponent(prefix)
            }
            let isLeaf = (index == prefixes.count - 1)
            if isLeaf && expectRegularFile {
                guard fileType == S_IFREG else {
                    throw StrictModesError.unexpectedFileType(prefix)
                }
            } else {
                guard fileType == S_IFDIR else {
                    throw StrictModesError.unexpectedFileType(prefix)
                }
            }
            guard st.st_uid == currentUID || st.st_uid == 0 else {
                throw StrictModesError.untrustedOwner(prefix, st.st_uid)
            }
            if (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
                throw StrictModesError.insecurePermissions(prefix, st.st_mode & 0o777)
            }
        }
    }

    /// Opens `path` as a descriptor-pinned directory (`O_DIRECTORY | O_NOFOLLOW`), verifying owner
    /// (`getuid()` or `0`) and absence of group/world write bits (`S_IWGRP | S_IWOTH`).
    public static func openVerifiedDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw StrictModesError.symlinkComponent(path)
            }
            if err == ENOTDIR {
                throw StrictModesError.unexpectedFileType(path)
            }
            throw StrictModesError.statFailed(path, String(cString: strerror(err)))
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let err = errno
            close(fd)
            throw StrictModesError.statFailed(path, String(cString: strerror(err)))
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw StrictModesError.unexpectedFileType(path)
        }
        let currentUID = getuid()
        guard st.st_uid == currentUID || st.st_uid == 0 else {
            close(fd)
            throw StrictModesError.untrustedOwner(path, st.st_uid)
        }
        if (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
            close(fd)
            throw StrictModesError.insecurePermissions(path, st.st_mode & 0o777)
        }
        return fd
    }

    /// Resolves macOS's immutable Signed System Volume `/var -> /private/var` root firmlink/symlink
    /// prefix while leaving all other components (including `/tmp` and user symlinks) untouched so
    /// every directory component under `/private/var/...` is still strictly verified (`01777`
    /// `/private/var/tmp` is rejected).
    public static func normalizeSystemVarPrefix(_ path: String) -> String {
        if path == "/var" {
            return "/private/var"
        }
        if path.hasPrefix("/var/") {
            return "/private" + path
        }
        return path
    }

    /// Strips C0 (`< 0x20`), DEL (`0x7F`), C1 (`0x80...0x9F`, including 8-bit CSI/OSC), and
    /// Unicode bidirectional override/isolate controls while collapsing whitespace to single spaces.
    public static func sanitizeTerminalText(_ raw: String, limit: Int? = nil) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(min(raw.unicodeScalars.count, limit ?? raw.unicodeScalars.count))
        var previousWasSpace = false

        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == " " {
                if !previousWasSpace && !scalars.isEmpty {
                    scalars.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            // Strip C0, DEL, C1 controls (0x80..0x9F), Unicode line/paragraph separators, and Bidi controls.
            if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F)
                || v == 0x061C || v == 0x200E || v == 0x200F
                || v == 0x2028 || v == 0x2029
                || (v >= 0x202A && v <= 0x202E)
                || (v >= 0x2066 && v <= 0x2069) {
                continue
            }
            scalars.append(scalar)
            previousWasSpace = false
        }
        while scalars.last == " " {
            scalars.removeLast()
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        guard let limit, cleaned.count > limit else { return cleaned }
        if limit <= 1 { return String(cleaned.prefix(limit)) }
        return String(cleaned.prefix(limit - 1)) + "…"
    }

    /// Sanitizes potentially multi-line terminal output (e.g. stderr error or hint lines),
    /// preserving intentional `\n` breaks while stripping ANSI/CSI/OSC, C0, C1, DEL, and Bidi controls.
    public static func sanitizeTerminalLines(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var scalars = String.UnicodeScalarView()
                scalars.reserveCapacity(line.unicodeScalars.count)
                for scalar in line.unicodeScalars {
                    let v = scalar.value
                    if scalar == "\t" {
                        scalars.append(" ")
                        continue
                    }
                    if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F)
                        || v == 0x061C || v == 0x200E || v == 0x200F
                        || v == 0x2028 || v == 0x2029
                        || (v >= 0x202A && v <= 0x202E)
                        || (v >= 0x2066 && v <= 0x2069) {
                        continue
                    }
                    scalars.append(scalar)
                }
                return String(scalars)
            }
            .joined(separator: "\n")
    }

    /// Creates and verifies every component of `directory` without following symlinks (`O_NOFOLLOW`
    /// + `mkdirat`), preventing intermediate symlink traversal both in normal mode and inside
    /// `HOTKEYD_HOME` sandboxes.
    public static func ensureSecureDirectory(at directory: URL, mode: mode_t = 0o700) throws {
        let normalizedTarget = normalizeSystemVarPrefix(directory.path)
        guard normalizedTarget.hasPrefix("/"), !normalizedTarget.contains("\0") else {
            throw StrictModesError.notAbsolutePath(directory.path)
        }
        let rawParts = normalizedTarget.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in rawParts where part == "." || part == ".." {
            throw StrictModesError.dotTraversalComponent(directory.path)
        }

        let currentUID = getuid()
        let startPath: String
        let componentsToWalk: [String]

        if Paths.isEnvironmentOverrideActive {
            let normalizedRoot = normalizeSystemVarPrefix(Paths.root.path)
            let rootTrimmed = normalizedRoot.hasSuffix("/") ? String(normalizedRoot.dropLast()) : normalizedRoot
            if normalizedTarget == rootTrimmed {
                startPath = normalizedTarget
                componentsToWalk = []
            } else if normalizedTarget.hasPrefix(rootTrimmed + "/") {
                startPath = rootTrimmed
                let tail = String(normalizedTarget.dropFirst(rootTrimmed.count + 1))
                componentsToWalk = tail.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            } else {
                startPath = "/"
                componentsToWalk = rawParts
            }
        } else {
            startPath = "/"
            componentsToWalk = rawParts
        }

        if startPath != "/" {
            // Ensure sandbox root exists without following a symlink at its final component.
            var rootStat = stat()
            if lstat(startPath, &rootStat) != 0 {
                if errno == ENOENT {
                    try FileManager.default.createDirectory(
                        atPath: startPath,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                } else {
                    throw StrictModesError.statFailed(startPath, String(cString: strerror(errno)))
                }
            } else if (rootStat.st_mode & S_IFMT) == S_IFLNK {
                throw StrictModesError.symlinkComponent(startPath)
            }
        }

        var currentFD = try openVerifiedDirectory(startPath)
        defer { close(currentFD) }

        var walkedPath = startPath == "/" ? "" : startPath
        for component in componentsToWalk {
            walkedPath += "/" + component
            var nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if nextFD < 0 && errno == ENOENT {
                if mkdirat(currentFD, component, mode) != 0 && errno != EEXIST {
                    throw StrictModesError.statFailed(walkedPath, String(cString: strerror(errno)))
                }
                nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextFD >= 0 else {
                let err = errno
                if err == ELOOP {
                    throw StrictModesError.symlinkComponent(walkedPath)
                }
                if err == ENOTDIR {
                    throw StrictModesError.unexpectedFileType(walkedPath)
                }
                throw StrictModesError.statFailed(walkedPath, String(cString: strerror(err)))
            }

            var st = stat()
            guard fstat(nextFD, &st) == 0 else {
                let err = errno
                close(nextFD)
                throw StrictModesError.statFailed(walkedPath, String(cString: strerror(err)))
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                close(nextFD)
                throw StrictModesError.unexpectedFileType(walkedPath)
            }
            guard st.st_uid == currentUID || st.st_uid == 0 else {
                close(nextFD)
                throw StrictModesError.untrustedOwner(walkedPath, st.st_uid)
            }
            if (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
                close(nextFD)
                throw StrictModesError.insecurePermissions(walkedPath, st.st_mode & 0o777)
            }

            close(currentFD)
            currentFD = nextFD
        }
    }

    /// Atomically writes `data` to `url` with exact POSIX mode `mode` (default `0o600`), using
    /// `openat` and `renameat` on a verified `O_NOFOLLOW` parent directory descriptor.
    public static func atomicWrite(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw StrictModesError.atomicWriteFailed(url.path, "invalid target filename '\(filename)'")
        }
        let normalizedDirPath = normalizeSystemVarPrefix(directory.path)
        if !Paths.isEnvironmentOverrideActive {
            try verifySecurePath(normalizedDirPath, expectRegularFile: false)
        } else {
            // Even in HOTKEYD_HOME sandboxes, ensure no symlinked intermediate dir escapes root.
            let normalizedRoot = normalizeSystemVarPrefix(Paths.root.path)
            let rootTrimmed = normalizedRoot.hasSuffix("/") ? String(normalizedRoot.dropLast()) : normalizedRoot
            if normalizedDirPath.hasPrefix(rootTrimmed + "/") {
                try ensureSecureDirectory(at: directory, mode: 0o700)
            }
        }
        let dirFD = try openVerifiedDirectory(normalizedDirPath)
        defer { close(dirFD) }

        let tempName = filename.hasPrefix(".")
            ? "\(filename).\(UUID().uuidString).tmp"
            : ".\(filename).\(UUID().uuidString).tmp"
        let fd = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else {
            throw StrictModesError.atomicWriteFailed(
                url.path,
                "could not create temporary file '\(tempName)': \(String(cString: strerror(errno)))"
            )
        }
        var succeeded = false
        defer {
            if !succeeded {
                _ = unlinkat(dirFD, tempName, 0)
            }
        }
        if fchmod(fd, mode) != 0 {
            let err = errno
            close(fd)
            throw StrictModesError.atomicWriteFailed(
                url.path,
                "could not set mode on '\(tempName)': \(String(cString: strerror(err)))"
            )
        }

        try data.withUnsafeBytes { rawBuffer in
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
                    let err = errno
                    close(fd)
                    throw StrictModesError.atomicWriteFailed(
                        url.path,
                        "could not write '\(tempName)': \(String(cString: strerror(err)))"
                    )
                }
                offset += written
            }
        }
        if fsync(fd) != 0 {
            let err = errno
            close(fd)
            throw StrictModesError.atomicWriteFailed(
                url.path,
                "fsync failed on '\(tempName)': \(String(cString: strerror(err)))"
            )
        }
        close(fd)

        guard renameat(dirFD, tempName, dirFD, filename) == 0 else {
            throw StrictModesError.atomicWriteFailed(
                url.path,
                "could not rename '\(tempName)' to '\(url.path)': \(String(cString: strerror(errno)))"
            )
        }
        succeeded = true
        _ = fsync(dirFD)
    }
}
