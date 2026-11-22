import Darwin
import Foundation

/// Atomic runtime health snapshot persisted by `hotkeyd daemon run` to `Paths.runtimeState`
/// (`0600`) so `hotkeyd status` and `hotkeyd doctor` report authoritative live daemon state
/// instead of grepping a rolling log file.
public struct RuntimeState: Codable, Sendable, Equatable {
    public static let maxFileSizeBytes: Int = 65_536

    public var pid: Int32
    public var startedAt: String
    public var updatedAt: String
    public var binaryPath: String
    public var configPath: String
    public var tapActive: Bool
    public var tapNote: String
    public var secureInputActive: Bool
    public var paused: Bool
    public var pausedUntil: String?
    public var pauseReason: String?
    public var capsRemapped: Bool
    public var peekEnabled: Bool?
    public var activeBindings: Int
    public var configValid: Bool
    public var configError: String?

    public init(
        pid: Int32,
        startedAt: String,
        updatedAt: String,
        binaryPath: String,
        configPath: String,
        tapActive: Bool,
        tapNote: String,
        secureInputActive: Bool = false,
        paused: Bool = false,
        pausedUntil: String? = nil,
        pauseReason: String? = nil,
        capsRemapped: Bool = false,
        peekEnabled: Bool? = nil,
        activeBindings: Int = 0,
        configValid: Bool = true,
        configError: String? = nil
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.tapActive = tapActive
        self.tapNote = tapNote
        self.secureInputActive = secureInputActive
        self.paused = paused
        self.pausedUntil = pausedUntil
        self.pauseReason = pauseReason
        self.capsRemapped = capsRemapped
        self.peekEnabled = peekEnabled
        self.activeBindings = activeBindings
        self.configValid = configValid
        self.configError = configError
    }

    private enum CodingKeys: String, CodingKey {
        case pid, startedAt, updatedAt, binaryPath, configPath
        case tapActive, tapNote, secureInputActive
        case paused, pausedUntil, pauseReason
        case capsRemapped, peekEnabled, activeBindings, configValid, configError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        binaryPath = try c.decode(String.self, forKey: .binaryPath)
        configPath = try c.decode(String.self, forKey: .configPath)
        tapActive = try c.decode(Bool.self, forKey: .tapActive)
        tapNote = try c.decode(String.self, forKey: .tapNote)
        secureInputActive = try c.decodeIfPresent(Bool.self, forKey: .secureInputActive) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        pausedUntil = try c.decodeIfPresent(String.self, forKey: .pausedUntil)
        pauseReason = try c.decodeIfPresent(String.self, forKey: .pauseReason)
        capsRemapped = try c.decodeIfPresent(Bool.self, forKey: .capsRemapped) ?? false
        peekEnabled = try c.decodeIfPresent(Bool.self, forKey: .peekEnabled)
        activeBindings = try c.decodeIfPresent(Int.self, forKey: .activeBindings) ?? 0
        configValid = try c.decodeIfPresent(Bool.self, forKey: .configValid) ?? true
        configError = try c.decodeIfPresent(String.self, forKey: .configError)
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func save(to url: URL = Paths.runtimeState) throws {
        let directory = url.deletingLastPathComponent()
        try StrictModes.ensureSecureDirectory(at: directory, mode: 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try StrictModes.atomicWrite(data, to: url, mode: 0o600)
    }

    public static func load(from url: URL = Paths.runtimeState) -> RuntimeState? {
        let filename = url.lastPathComponent
        let parentPath = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return nil
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(parentPath) else {
            return nil
        }
        defer { close(dirFD) }

        let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o077) == 0,
              st.st_size > 0,
              st.st_size <= off_t(maxFileSizeBytes) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(fd, base, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            if data.count > maxFileSizeBytes {
                return nil
            }
        }
        return try? JSONDecoder().decode(RuntimeState.self, from: data)
    }

    public static func remove(at url: URL = Paths.runtimeState, expectedPID: Int32? = nil) {
        if let expectedPID, let existing = load(from: url), existing.pid != expectedPID {
            return
        }
        let filename = url.lastPathComponent
        let parentPath = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(parentPath) else {
            return
        }
        defer { close(dirFD) }
        _ = unlinkat(dirFD, filename, 0)
    }

    /// Writes a short-lived `0600` one-shot sentinel telling the daemon not to pop a competing
    /// `AXIsProcessTrustedWithOptions(prompt: true)` modal alert (e.g., when `hotkeyd init` is
    /// opening System Settings directly or running in `--non-interactive` / `--no-open` mode).
    public static func writeSuppressAXPromptSentinel(
        to url: URL = Paths.suppressAXPromptSentinel
    ) throws {
        let directory = url.deletingLastPathComponent()
        try StrictModes.ensureSecureDirectory(at: directory, mode: 0o700)
        let payload = Data("\(Int(Date().timeIntervalSince1970))\n".utf8)
        try StrictModes.atomicWrite(payload, to: url, mode: 0o600)
    }

    /// Consumes (unlinks) the one-shot AX-prompt suppression sentinel and returns `true` iff a
    /// valid, user-owned `0600` regular file existed and is newer than `maxAgeSeconds`.
    public static func consumeSuppressAXPromptSentinel(
        at url: URL = Paths.suppressAXPromptSentinel,
        maxAgeSeconds: TimeInterval = 15
    ) -> Bool {
        let filename = url.lastPathComponent
        let parentPath = StrictModes.normalizeSystemVarPrefix(url.deletingLastPathComponent().path)
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            return false
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(parentPath) else {
            return false
        }
        defer { close(dirFD) }

        let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        var st = stat()
        let statOK = fstat(fd, &st) == 0
        close(fd)
        _ = unlinkat(dirFD, filename, 0)

        guard statOK,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o077) == 0 else {
            return false
        }
        let mtime = TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
        let age = Date().timeIntervalSince1970 - mtime
        return age >= -5 && age <= maxAgeSeconds
    }
}
