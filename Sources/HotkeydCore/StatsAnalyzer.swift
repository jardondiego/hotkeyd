import Darwin
import Foundation

public struct StatsWindow: Equatable, Sendable {
    public let label: String
    public let cutoff: Date?

    public init(label: String, cutoff: Date?) {
        self.label = label
        self.cutoff = cutoff
    }

    /// Parses `--since` values: `all`, `<N>m`, `<N>h`, `<N>d`, `<N>w`, or `YYYY-MM-DD`.
    public static func parse(_ raw: String, now: Date = Date()) -> StatsWindow? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "all" {
            return StatsWindow(label: "all", cutoff: nil)
        }

        // ISO date YYYY-MM-DD (UTC midnight)
        if trimmed.count == 10, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-",
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)] == "-" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: trimmed) {
                return StatsWindow(label: trimmed, cutoff: date)
            }
            return nil
        }

        guard let unit = lowered.last else { return nil }
        let numberPart = lowered.dropLast()
        guard let amount = Int(numberPart), amount > 0, amount <= 36_500 else {
            return nil
        }

        let multiplier: TimeInterval
        switch unit {
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        case "w": multiplier = 604_800
        default: return nil
        }
        return StatsWindow(
            label: "\(amount)\(unit)",
            cutoff: now.addingTimeInterval(-TimeInterval(amount) * multiplier)
        )
    }
}

public enum ActionLogOutcome: Equatable, Sendable {
    case exited(Int)
    case timedOut
    case dropped

    public var isSuccess: Bool {
        if case .exited(0) = self { return true }
        return false
    }
}

public struct ActionLogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let shortcutName: String
    public let outcome: ActionLogOutcome
    public let durationMs: Int?
    public let actionSummary: String?

    public init(
        timestamp: Date,
        shortcutName: String,
        outcome: ActionLogOutcome,
        durationMs: Int?,
        actionSummary: String?
    ) {
        self.timestamp = timestamp
        self.shortcutName = shortcutName
        self.outcome = outcome
        self.durationMs = durationMs
        self.actionSummary = actionSummary
    }
}

public enum ParsedActionLogLine: Equatable, Sendable {
    case event(ActionLogEntry)
    case stderr(timestamp: Date, shortcutName: String, message: String)
}

public struct ExecutionModeStats: Codable, Sendable, Equatable {
    public let count: Int
    public let avgMs: Int?
    public let medianMs: Int?
    public let p95Ms: Int?

    public init(count: Int, avgMs: Int?, medianMs: Int?, p95Ms: Int?) {
        self.count = count
        self.avgMs = avgMs
        self.medianMs = medianMs
        self.p95Ms = p95Ms
    }
}

public struct ShortcutUsageStats: Codable, Sendable, Equatable {
    public let name: String
    public let keys: String?
    public let status: String
    public let executionMode: String
    public let count: Int
    public let successCount: Int
    public let failureCount: Int
    public let timeoutCount: Int
    public let droppedCount: Int
    public let avgMs: Int?
    public let medianMs: Int?
    public let p95Ms: Int?
    public let maxMs: Int?
    public let lastUsedAt: String?
    public let lastError: String?

    public init(
        name: String,
        keys: String?,
        status: String,
        executionMode: String,
        count: Int,
        successCount: Int,
        failureCount: Int,
        timeoutCount: Int,
        droppedCount: Int,
        avgMs: Int?,
        medianMs: Int?,
        p95Ms: Int?,
        maxMs: Int?,
        lastUsedAt: String?,
        lastError: String?
    ) {
        self.name = name
        self.keys = keys
        self.status = status
        self.executionMode = executionMode
        self.count = count
        self.successCount = successCount
        self.failureCount = failureCount
        self.timeoutCount = timeoutCount
        self.droppedCount = droppedCount
        self.avgMs = avgMs
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.lastUsedAt = lastUsedAt
        self.lastError = lastError
    }
}

public struct StatsAlert: Codable, Sendable, Equatable {
    public let kind: String
    public let name: String
    public let keys: String?
    public let detail: String

    public init(kind: String, name: String, keys: String?, detail: String) {
        self.kind = kind
        self.name = name
        self.keys = keys
        self.detail = detail
    }
}

public struct UnusedShortcutEntry: Codable, Sendable, Equatable {
    public let keys: String
    public let name: String
    public let executionMode: String
    public let commandPreview: String

    public init(keys: String, name: String, executionMode: String, commandPreview: String) {
        self.keys = keys
        self.name = name
        self.executionMode = executionMode
        self.commandPreview = commandPreview
    }
}

public struct StatsReport: Codable, Sendable, Equatable {
    public let window: String
    public let totalEvents: Int
    public let successCount: Int
    public let failureCount: Int
    public let timeoutCount: Int
    public let droppedCount: Int
    public let successRatePercent: Double
    public let firstEventAt: String?
    public let lastEventAt: String?
    public let filesScanned: [String]
    public let configuredShortcuts: Int
    public let enabledShortcuts: Int
    public let nativeSummary: ExecutionModeStats
    public let shellSummary: ExecutionModeStats
    public let shortcuts: [ShortcutUsageStats]
    public let alerts: [StatsAlert]
    public let unusedShortcuts: [UnusedShortcutEntry]

    public init(
        window: String,
        totalEvents: Int,
        successCount: Int,
        failureCount: Int,
        timeoutCount: Int,
        droppedCount: Int,
        successRatePercent: Double,
        firstEventAt: String?,
        lastEventAt: String?,
        filesScanned: [String],
        configuredShortcuts: Int,
        enabledShortcuts: Int,
        nativeSummary: ExecutionModeStats,
        shellSummary: ExecutionModeStats,
        shortcuts: [ShortcutUsageStats],
        alerts: [StatsAlert],
        unusedShortcuts: [UnusedShortcutEntry]
    ) {
        self.window = window
        self.totalEvents = totalEvents
        self.successCount = successCount
        self.failureCount = failureCount
        self.timeoutCount = timeoutCount
        self.droppedCount = droppedCount
        self.successRatePercent = successRatePercent
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.filesScanned = filesScanned
        self.configuredShortcuts = configuredShortcuts
        self.enabledShortcuts = enabledShortcuts
        self.nativeSummary = nativeSummary
        self.shellSummary = shellSummary
        self.shortcuts = shortcuts
        self.alerts = alerts
        self.unusedShortcuts = unusedShortcuts
    }
}

public enum StatsAnalyzer {
    public static let maxLogFileBytes: Int = 6_291_456 // 6 MiB (rotated cap is 5 MiB)
    public static let slowShortcutThresholdMs: Int = 1_000
    public static let maxDurationMs: Int = 86_400_000 // 24h cap preventing integer overflow

    public struct LogFileStat: Equatable, Sendable {
        public let dev: UInt64
        public let ino: UInt64
        public let size: Int64
        public let mtimeSec: Int64
        public let mtimeNsec: Int64

        public init(dev: UInt64, ino: UInt64, size: Int64, mtimeSec: Int64, mtimeNsec: Int64) {
            self.dev = dev
            self.ino = ino
            self.size = size
            self.mtimeSec = mtimeSec
            self.mtimeNsec = mtimeNsec
        }
    }

    public struct LogFingerprint: Equatable, Sendable {
        public let rotated: LogFileStat?
        public let current: LogFileStat?

        public init(rotated: LogFileStat?, current: LogFileStat?) {
            self.rotated = rotated
            self.current = current
        }
    }

    /// Cheap metadata fingerprint (`fstatat` with `AT_SYMLINK_NOFOLLOW`, zero file reads) for
    /// caching shortcut usage counts across Search HUD toggles.
    public static func logsFingerprint(logsDirectory: URL = Paths.logs) -> LogFingerprint {
        let normalizedDir = StrictModes.normalizeSystemVarPrefix(logsDirectory.path)
        if !Paths.isEnvironmentOverrideActive,
           (try? StrictModes.verifySecurePath(normalizedDir, expectRegularFile: false)) == nil {
            return LogFingerprint(rotated: nil, current: nil)
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(normalizedDir) else {
            return LogFingerprint(rotated: nil, current: nil)
        }
        defer { close(dirFD) }

        func statFile(_ name: String) -> LogFileStat? {
            var st = stat()
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG,
                  st.st_uid == getuid(),
                  (st.st_mode & 0o077) == 0,
                  st.st_size > 0,
                  st.st_size <= off_t(maxLogFileBytes) else {
                return nil
            }
            return LogFileStat(
                dev: UInt64(bitPattern: Int64(st.st_dev)),
                ino: UInt64(st.st_ino),
                size: Int64(st.st_size),
                mtimeSec: Int64(st.st_mtimespec.tv_sec),
                mtimeNsec: Int64(st.st_mtimespec.tv_nsec)
            )
        }

        return LogFingerprint(
            rotated: statFile("actions.log.1"),
            current: statFile("actions.log")
        )
    }

    /// Lightweight frequency tally keyed by lowercased single-line shortcut identifier (display
    /// name or canonical keys), avoiding full `StatsReport` allocation on hot paths like Search HUD.
    public static func loadShortcutCounts(logsDirectory: URL = Paths.logs) -> [String: Int] {
        var counts: [String: Int] = [:]
        for filename in ["actions.log.1", "actions.log"] {
            guard let text = readVerifiedLogFile(directory: logsDirectory, filename: filename) else {
                continue
            }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if case .event(let entry) = parseActionLogLine(String(rawLine)) {
                    let key = singleLine(entry.shortcutName).lowercased()
                    if !key.isEmpty {
                        counts[key, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    /// Loads `actions.log.1` and `actions.log` safely (`O_NOFOLLOW`, `0600`, user-owned regular
    /// files, verified ancestors) and computes aggregated usage, latency, failure alerts, and
    /// unused-shortcut diagnostics.
    public static func analyze(
        logsDirectory: URL = Paths.logs,
        config: Config?,
        window: StatsWindow = StatsWindow(label: "all", cutoff: nil)
    ) -> StatsReport {
        var parsedLines: [ParsedActionLogLine] = []
        var scannedFiles: [String] = []

        for filename in ["actions.log.1", "actions.log"] {
            if let text = readVerifiedLogFile(directory: logsDirectory, filename: filename) {
                scannedFiles.append(filename)
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    if let parsed = parseActionLogLine(String(rawLine)) {
                        parsedLines.append(parsed)
                    }
                }
            }
        }

        return aggregate(
            parsedLines: parsedLines,
            filesScanned: scannedFiles,
            config: config,
            window: window
        )
    }

    /// Pure aggregation entry point (also directly unit-testable without disk I/O).
    public static func aggregate(
        parsedLines: [ParsedActionLogLine],
        filesScanned: [String],
        config: Config?,
        window: StatsWindow
    ) -> StatsReport {
        let configuredList = config?.shortcuts ?? []
        var configByDisplayName: [String: Shortcut] = [:]
        var configByCanonical: [String: Shortcut] = [:]
        for shortcut in configuredList {
            configByDisplayName[singleLine(shortcut.displayName)] = shortcut
            configByCanonical[singleLine(shortcut.keys.canonical)] = shortcut
        }

        struct Bucket {
            var count: Int = 0
            var successCount: Int = 0
            var failureCount: Int = 0
            var timeoutCount: Int = 0
            var droppedCount: Int = 0
            var durations: [Int] = []
            var lastUsed: Date?
            var lastError: String?
            var nativeVotes: Int = 0
            var shellVotes: Int = 0
        }

        var buckets: [String: Bucket] = [:]
        var totalEvents = 0
        var totalSuccess = 0
        var totalFailure = 0
        var totalTimeouts = 0
        var totalDropped = 0
        var firstDate: Date?
        var lastDate: Date?
        var nativeDurations: [Int] = []
        var shellDurations: [Int] = []
        var nativeCount = 0
        var shellCount = 0

        for item in parsedLines {
            switch item {
            case .stderr(let ts, let name, let message):
                if let cutoff = window.cutoff, ts < cutoff { continue }
                let matched = configByDisplayName[name] ?? configByCanonical[name]
                let bucketKey = matched.map { singleLine($0.displayName) } ?? name
                var bucket = buckets[bucketKey] ?? Bucket()
                bucket.lastError = message
                buckets[bucketKey] = bucket

            case .event(let entry):
                if let cutoff = window.cutoff, entry.timestamp < cutoff { continue }

                totalEvents += 1
                if firstDate == nil || entry.timestamp < firstDate! { firstDate = entry.timestamp }
                if lastDate == nil || entry.timestamp > lastDate! { lastDate = entry.timestamp }

                let matchedShortcut = configByDisplayName[entry.shortcutName] ?? configByCanonical[entry.shortcutName]
                let bucketKey = matchedShortcut.map { singleLine($0.displayName) } ?? entry.shortcutName
                let isNative = classifyNative(shortcut: matchedShortcut, actionSummary: entry.actionSummary)
                if isNative {
                    nativeCount += 1
                    if let ms = entry.durationMs { nativeDurations.append(ms) }
                } else {
                    shellCount += 1
                    if let ms = entry.durationMs { shellDurations.append(ms) }
                }

                var bucket = buckets[bucketKey] ?? Bucket()
                bucket.count += 1
                if isNative { bucket.nativeVotes += 1 } else { bucket.shellVotes += 1 }
                switch entry.outcome {
                case .exited(0):
                    totalSuccess += 1
                    bucket.successCount += 1
                case .exited:
                    totalFailure += 1
                    bucket.failureCount += 1
                case .timedOut:
                    totalFailure += 1
                    totalTimeouts += 1
                    bucket.failureCount += 1
                    bucket.timeoutCount += 1
                case .dropped:
                    totalFailure += 1
                    totalDropped += 1
                    bucket.failureCount += 1
                    bucket.droppedCount += 1
                }
                if let ms = entry.durationMs {
                    bucket.durations.append(ms)
                }
                if bucket.lastUsed == nil || entry.timestamp > bucket.lastUsed! {
                    bucket.lastUsed = entry.timestamp
                }
                buckets[bucketKey] = bucket
            }
        }

        // Build per-shortcut rows (ignoring stderr-only ghosts with 0 events).
        var usedConfigKeys: Set<String> = []
        var shortcutStats: [ShortcutUsageStats] = []
        shortcutStats.reserveCapacity(buckets.count)

        for (name, bucket) in buckets where bucket.count > 0 {
            let matched = configByDisplayName[name] ?? configByCanonical[name]
            if let matched {
                usedConfigKeys.insert(matched.keys.canonical)
            }
            let status: String
            if let matched {
                status = matched.enabled ? "active" : "disabled"
            } else {
                status = "removed"
            }
            let mode: String
            if let matched {
                mode = matched.primaryExecutionMode == "shell" ? "shell" : "native"
            } else {
                mode = bucket.nativeVotes >= bucket.shellVotes ? "native" : "shell"
            }
            let latency = computeLatency(bucket.durations)
            let maxMs = bucket.durations.max()

            shortcutStats.append(ShortcutUsageStats(
                name: singleLine(name),
                keys: matched?.keys.canonical,
                status: status,
                executionMode: mode,
                count: bucket.count,
                successCount: bucket.successCount,
                failureCount: bucket.failureCount,
                timeoutCount: bucket.timeoutCount,
                droppedCount: bucket.droppedCount,
                avgMs: latency.avgMs,
                medianMs: latency.medianMs,
                p95Ms: latency.p95Ms,
                maxMs: maxMs,
                lastUsedAt: bucket.lastUsed.map { RuntimeState.timestamp($0) },
                lastError: bucket.failureCount > 0 ? bucket.lastError.map { singleLine($0) } : nil
            ))
        }

        shortcutStats.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.lastUsedAt != rhs.lastUsedAt { return (lhs.lastUsedAt ?? "") > (rhs.lastUsedAt ?? "") }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // Health alerts: failures first, then slow shortcuts (median >= 1000ms).
        var alerts: [StatsAlert] = []
        for item in shortcutStats where item.failureCount > 0 {
            var parts: [String] = []
            let nonZeroExits = item.failureCount - item.timeoutCount - item.droppedCount
            if nonZeroExits > 0 { parts.append("\(nonZeroExits) exit error(s)") }
            if item.timeoutCount > 0 { parts.append("\(item.timeoutCount) timeout(s)") }
            if item.droppedCount > 0 { parts.append("\(item.droppedCount) dropped") }
            var detail = parts.joined(separator: ", ") + " out of \(item.count) run(s)"
            if let err = item.lastError, !err.isEmpty {
                detail += " — last stderr: \(truncate(err, limit: 80))"
            }
            alerts.append(StatsAlert(kind: "failure", name: item.name, keys: item.keys, detail: detail))
        }
        for item in shortcutStats where item.failureCount == 0 {
            if let median = item.medianMs, median >= slowShortcutThresholdMs {
                let p95Text = item.p95Ms.map { ", p95 \($0) ms" } ?? ""
                alerts.append(StatsAlert(
                    kind: "slow",
                    name: item.name,
                    keys: item.keys,
                    detail: "median \(median) ms\(p95Text) across \(item.count) run(s)"
                ))
            }
        }

        // Unused enabled shortcuts (0 fires in observed window).
        let enabledList = configuredList.filter(\.enabled)
        let unused: [UnusedShortcutEntry] = enabledList
            .filter { !usedConfigKeys.contains($0.keys.canonical) }
            .map { shortcut in
                let mode = shortcut.primaryExecutionMode == "shell" ? "shell" : "native"
                return UnusedShortcutEntry(
                    keys: shortcut.keys.canonical,
                    name: singleLine(shortcut.displayName),
                    executionMode: mode,
                    commandPreview: truncate(singleLine(shortcut.activeCommand), limit: 60)
                )
            }

        let successRate: Double
        if totalEvents > 0 {
            successRate = ((Double(totalSuccess) / Double(totalEvents)) * 1000.0).rounded() / 10.0
        } else {
            successRate = 100.0
        }

        let nativeLatency = computeLatency(nativeDurations)
        let shellLatency = computeLatency(shellDurations)

        return StatsReport(
            window: window.label,
            totalEvents: totalEvents,
            successCount: totalSuccess,
            failureCount: totalFailure,
            timeoutCount: totalTimeouts,
            droppedCount: totalDropped,
            successRatePercent: successRate,
            firstEventAt: firstDate.map { RuntimeState.timestamp($0) },
            lastEventAt: lastDate.map { RuntimeState.timestamp($0) },
            filesScanned: filesScanned,
            configuredShortcuts: configuredList.count,
            enabledShortcuts: enabledList.count,
            nativeSummary: ExecutionModeStats(
                count: nativeCount,
                avgMs: nativeLatency.avgMs,
                medianMs: nativeLatency.medianMs,
                p95Ms: nativeLatency.p95Ms
            ),
            shellSummary: ExecutionModeStats(
                count: shellCount,
                avgMs: shellLatency.avgMs,
                medianMs: shellLatency.medianMs,
                p95Ms: shellLatency.p95Ms
            ),
            shortcuts: shortcutStats,
            alerts: alerts,
            unusedShortcuts: unused
        )
    }

    // MARK: - Line parser (handles spaces inside shortcut names!)

    public static func parseActionLogLine(_ line: String) -> ParsedActionLogLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = trimmed.range(of: " action shortcut=") else {
            return nil
        }

        let timestampRaw = String(trimmed[..<markerRange.lowerBound])
        guard let timestamp = parseISO8601(timestampRaw) else {
            return nil
        }

        let rest = String(trimmed[markerRange.upperBound...])
        guard !rest.isEmpty else { return nil }

        // 1. Continuation stderr line: `<name> stderr=<detail>`
        if let stderrRange = rest.range(of: " stderr=") {
            let name = String(rest[..<stderrRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let message = String(rest[stderrRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return .stderr(timestamp: timestamp, shortcutName: name, message: message)
        }

        // 2. Concurrency drop: `<name> dropped (...)`
        if let dropRange = rest.range(of: " dropped") {
            let suffix = rest[dropRange.upperBound...]
            if suffix.isEmpty || suffix.hasPrefix(" ") {
                let name = String(rest[..<dropRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return .event(ActionLogEntry(
                    timestamp: timestamp,
                    shortcutName: name,
                    outcome: .dropped,
                    durationMs: nil,
                    actionSummary: nil
                ))
            }
        }

        // 3. Normal completion or timeout: `<name> <exit=N|timeout> <ms>ms action=<summary>`
        // Anchor on ` action=` and walk backward by two whitespace-separated tokens so spaces inside
        // `<name>` (e.g. "VS Code", "Sequence Test", "Home Folder") are preserved verbatim.
        guard let actionRange = rest.range(of: " action=") else {
            return nil
        }
        let header = String(rest[..<actionRange.lowerBound])
        let summary = String(rest[actionRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        guard let lastSpace = header.lastIndex(of: " ") else { return nil }
        let msToken = String(header[header.index(after: lastSpace)...])
        guard msToken.hasSuffix("ms"),
              let durationMs = Int(msToken.dropLast(2)),
              durationMs >= 0,
              durationMs <= maxDurationMs else {
            return nil
        }

        let beforeMs = String(header[..<lastSpace])
        guard let outcomeSpace = beforeMs.lastIndex(of: " ") else { return nil }
        let outcomeToken = String(beforeMs[beforeMs.index(after: outcomeSpace)...])
        let name = String(beforeMs[..<outcomeSpace]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let outcome: ActionLogOutcome
        if outcomeToken == "timeout" {
            outcome = .timedOut
        } else if outcomeToken.hasPrefix("exit="),
                  let exitCode = Int(outcomeToken.dropFirst("exit=".count)) {
            outcome = .exited(exitCode)
        } else {
            return nil
        }

        return .event(ActionLogEntry(
            timestamp: timestamp,
            shortcutName: name,
            outcome: outcome,
            durationMs: durationMs,
            actionSummary: summary.isEmpty ? nil : summary
        ))
    }

    // MARK: - Helpers

    private static func readVerifiedLogFile(directory: URL, filename: String) -> String? {
        let normalizedDir = StrictModes.normalizeSystemVarPrefix(directory.path)
        if !Paths.isEnvironmentOverrideActive,
           (try? StrictModes.verifySecurePath(normalizedDir, expectRegularFile: false)) == nil {
            return nil
        }
        guard let dirFD = try? StrictModes.openVerifiedDirectory(normalizedDir) else {
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
              st.st_size <= off_t(maxLogFileBytes) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
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
            if data.count > maxLogFileBytes {
                return nil
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func classifyNative(shortcut: Shortcut?, actionSummary: String?) -> Bool {
        if let shortcut {
            return shortcut.primaryExecutionMode != "shell"
        }
        if let summary = actionSummary, Action.migratedFromShellCommand(summary) != nil {
            return true
        }
        return false
    }

    private static func computeLatency(_ durations: [Int]) -> (avgMs: Int?, medianMs: Int?, p95Ms: Int?) {
        let clamped = durations.map { max(0, min($0, maxDurationMs)) }
        guard !clamped.isEmpty else { return (nil, nil, nil) }
        let sorted = clamped.sorted()
        let sum = sorted.reduce(0.0) { $0 + Double($1) }
        let avg = Int((sum / Double(sorted.count)).rounded())
        let mid = sorted.count / 2
        let median: Int
        if sorted.count % 2 == 1 {
            median = sorted[mid]
        } else {
            median = Int(((Double(sorted[mid - 1]) + Double(sorted[mid])) / 2.0).rounded())
        }
        let p95Index = min(sorted.count - 1, max(0, Int(ceil(0.95 * Double(sorted.count))) - 1))
        return (avg, median, sorted[p95Index])
    }

    /// Allocation-free, thread-safe RFC 3339 / ISO-8601 timestamp parser (`YYYY-MM-DDTHH:MM:SS[.f+](Z|±HH:MM|±HHMM)`).
    /// Avoids per-line `ISO8601DateFormatter` / ICU allocation when scanning multi-megabyte logs.
    private static func parseISO8601(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8)
        // Minimum valid length: "YYYY-MM-DDTHH:MM:SSZ" (20 bytes)
        guard bytes.count >= 20, bytes.count <= 40 else { return nil }

        func parseDigits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for i in start..<(start + count) {
                let b = bytes[i]
                guard b >= 0x30 && b <= 0x39 else { return nil }
                value = value * 10 + Int(b - 0x30)
            }
            return value
        }

        // Separators: YYYY-MM-DD[T|t]HH:MM:SS
        guard bytes[4] == 0x2D, // '-'
              bytes[7] == 0x2D, // '-'
              (bytes[10] == 0x54 || bytes[10] == 0x74), // 'T' or 't'
              bytes[13] == 0x3A, // ':'
              bytes[16] == 0x3A else { // ':'
            return nil
        }

        guard let year = parseDigits(0, 4),
              let month = parseDigits(5, 2),
              let day = parseDigits(8, 2),
              let hour = parseDigits(11, 2),
              let minute = parseDigits(14, 2),
              let second = parseDigits(17, 2) else {
            return nil
        }

        guard (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }

        let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
        let maxDay: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: maxDay = 31
        case 4, 6, 9, 11: maxDay = 30
        case 2: maxDay = isLeap ? 29 : 28
        default: return nil
        }
        guard (1...maxDay).contains(day) else { return nil }

        var idx = 19
        var fractionalSeconds = 0.0
        if idx < bytes.count && bytes[idx] == 0x2E { // '.'
            idx += 1
            let fracStart = idx
            var scale = 0.1
            while idx < bytes.count && bytes[idx] >= 0x30 && bytes[idx] <= 0x39 {
                if idx - fracStart < 9 {
                    fractionalSeconds += Double(bytes[idx] - 0x30) * scale
                    scale *= 0.1
                }
                idx += 1
            }
            guard idx > fracStart else { return nil }
        }

        guard idx < bytes.count else { return nil }
        let tzOffsetSeconds: Int
        let tzByte = bytes[idx]
        if tzByte == 0x5A || tzByte == 0x7A { // 'Z' or 'z'
            idx += 1
            guard idx == bytes.count else { return nil }
            tzOffsetSeconds = 0
        } else if tzByte == 0x2B || tzByte == 0x2D { // '+' or '-'
            let sign = (tzByte == 0x2B) ? 1 : -1
            idx += 1
            guard let tzHour = parseDigits(idx, 2) else { return nil }
            idx += 2
            if idx < bytes.count && bytes[idx] == 0x3A { // optional ':'
                idx += 1
            }
            guard let tzMinute = parseDigits(idx, 2) else { return nil }
            idx += 2
            guard idx == bytes.count, (0...23).contains(tzHour), (0...59).contains(tzMinute) else {
                return nil
            }
            tzOffsetSeconds = sign * (tzHour * 3600 + tzMinute * 60)
        } else {
            return nil
        }

        // Hinnant's days_from_civil: days since 1970-01-01 (Gregorian calendar).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = Int64(era) * 146_097 + Int64(doe) - 719_468

        let wholeSeconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(tzOffsetSeconds)
        return Date(timeIntervalSince1970: Double(wholeSeconds) + fractionalSeconds)
    }

    private static func singleLine(_ text: String) -> String {
        StrictModes.sanitizeTerminalText(text)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(limit)) }
        return String(text.prefix(limit - 1)) + "…"
    }
}
