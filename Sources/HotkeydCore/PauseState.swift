import Darwin
import Foundation

/// Stateless `0600` pause control state persisted at `Paths.pauseState` (`pause-state.json`)
/// so `hotkeyd pause [--for <duration>]` and `hotkeyd resume` can disarm/re-arm the daemon via
/// `SIGHUP` without introducing a socket or IPC protocol.
public struct PauseState: Codable, Sendable, Equatable {
    public static let maxFileSizeBytes: Int = 16_384
    public static let minDurationSeconds: TimeInterval = 5
    public static let maxDurationSeconds: TimeInterval = 86_400 // 24h
    public static let maxReasonLength: Int = 120

    public let pausedAt: String
    public let resumeAt: String?
    public let reason: String?

    public init(pausedAt: String, resumeAt: String? = nil, reason: String? = nil) {
        self.pausedAt = pausedAt
        self.resumeAt = resumeAt
        if let reason {
            let cleaned = Self.sanitizeReason(reason)
            self.reason = cleaned.isEmpty ? nil : cleaned
        } else {
            self.reason = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pausedAt, resumeAt, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPausedAt = try container.decode(String.self, forKey: .pausedAt)
        let decodedResumeAt = try container.decodeIfPresent(String.self, forKey: .resumeAt)
        let decodedReason = try container.decodeIfPresent(String.self, forKey: .reason)
        self.init(pausedAt: decodedPausedAt, resumeAt: decodedResumeAt, reason: decodedReason)
    }

    public init(pausedAtDate: Date = Date(), durationSeconds: TimeInterval? = nil, reason: String? = nil) {
        let resume = durationSeconds.map { pausedAtDate.addingTimeInterval($0) }
        self.init(
            pausedAt: RuntimeState.timestamp(pausedAtDate),
            resumeAt: resume.map { RuntimeState.timestamp($0) },
            reason: reason
        )
    }

    public var resumeDate: Date? {
        guard let resumeAt else { return nil }
        return Self.parseISO8601(resumeAt)
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let resumeAt else { return false }
        guard let target = Self.parseISO8601(resumeAt) else {
            // Corrupt resumeAt fails safe by treating pause as expired.
            return true
        }
        return now >= target
    }

    public func remainingSeconds(at now: Date = Date()) -> Int? {
        guard let target = resumeDate else { return nil }
        return max(0, Int(ceil(target.timeIntervalSince(now))))
    }

    public func formattedRemaining(at now: Date = Date()) -> String? {
        guard let seconds = remainingSeconds(at: now) else { return nil }
        return Self.formatDuration(seconds)
    }

    // MARK: - Persistence (`0600`, `O_NOFOLLOW`, verified parent directory)

    public func save(to url: URL = Paths.pauseState) throws {
        let directory = url.deletingLastPathComponent()
        try StrictModes.ensureSecureDirectory(at: directory, mode: 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try StrictModes.atomicWrite(data, to: url, mode: 0o600)
    }

    public static func load(from url: URL = Paths.pauseState) -> PauseState? {
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
            let count = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > maxFileSizeBytes {
                return nil
            }
        }
        return try? JSONDecoder().decode(PauseState.self, from: data)
    }

    public static func loadActive(
        from url: URL = Paths.pauseState,
        now: Date = Date(),
        pruneExpired: Bool = false
    ) -> PauseState? {
        guard let state = load(from: url) else { return nil }
        if state.isExpired(at: now) {
            if pruneExpired {
                clear(at: url)
            }
            return nil
        }
        return state
    }

    public static func clear(at url: URL = Paths.pauseState) {
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

    // MARK: - Duration parsing & formatting

    /// Parses positive durations like `30s`, `15m`, `2h`, `1h30m`, `1h30m15s` (bounds: 5s..24h).
    public static func parseDurationSeconds(_ raw: String) -> TimeInterval? {
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return nil }

        var totalSeconds: Int64 = 0
        var digits = ""
        var lastRank = 0 // 1=h, 2=m, 3=s (enforces strictly descending unique units)

        for ch in compact {
            if ch.isNumber {
                digits.append(ch)
                if digits.count > 6 { return nil }
            } else if ch == "h" || ch == "m" || ch == "s" {
                guard !digits.isEmpty, let value = Int64(digits), value > 0 else {
                    return nil
                }
                let rank: Int
                let multiplier: Int64
                switch ch {
                case "h":
                    rank = 1
                    multiplier = 3_600
                case "m":
                    rank = 2
                    multiplier = 60
                default:
                    rank = 3
                    multiplier = 1
                }
                guard rank > lastRank else { return nil }
                lastRank = rank
                totalSeconds += value * multiplier
                digits = ""
            } else {
                return nil
            }
        }

        // Reject trailing bare numbers with no unit
        guard digits.isEmpty else { return nil }
        let interval = TimeInterval(totalSeconds)
        guard interval >= minDurationSeconds && interval <= maxDurationSeconds else {
            return nil
        }
        return interval
    }

    public static func formatDuration(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let seconds = clamped % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 && hours == 0 { parts.append("\(seconds)s") }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }

    public static func sanitizeReason(_ raw: String) -> String {
        StrictModes.sanitizeTerminalText(raw, limit: maxReasonLength)
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}
