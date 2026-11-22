import Foundation
import HotkeydCore

func commandStats(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: ["since", "top"],
        switches: ["unused", "json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["stats"])
        return
    }

    let rawSince = parsed.values["since"] ?? "all"
    guard let window = StatsWindow.parse(rawSince) else {
        throw CLIError(
            message: "invalid --since value '\(rawSince)' (expected all, 7d, 30d, 24h, 30m, 2w, or YYYY-MM-DD)",
            code: 2,
            hint: "example: hotkeyd stats --since 7d"
        )
    }

    let topLimit: Int?
    if let rawTop = parsed.values["top"] {
        guard let parsedTop = Int(rawTop), parsedTop > 0 else {
            throw CLIError(
                message: "invalid --top value '\(rawTop)' (must be a positive integer)",
                code: 2
            )
        }
        topLimit = parsedTop
    } else {
        topLimit = nil
    }

    let config: Config?
    do {
        config = try Config.load(from: Paths.config)
    } catch ConfigError.fileMissing {
        config = nil
    } catch {
        throw CLIError(
            message: "could not load \(Paths.config.path): \(error.localizedDescription)",
            code: 7,
            kind: "config_io",
            hint: "fix \(Paths.config.path) or run `hotkeyd doctor`"
        )
    }

    let fullReport = StatsAnalyzer.analyze(
        logsDirectory: Paths.logs,
        config: config,
        window: window
    )

    if wantsJSON(parsed) {
        let jsonReport: StatsReport
        if let topLimit, fullReport.shortcuts.count > topLimit {
            jsonReport = StatsReport(
                window: fullReport.window,
                totalEvents: fullReport.totalEvents,
                successCount: fullReport.successCount,
                failureCount: fullReport.failureCount,
                timeoutCount: fullReport.timeoutCount,
                droppedCount: fullReport.droppedCount,
                successRatePercent: fullReport.successRatePercent,
                firstEventAt: fullReport.firstEventAt,
                lastEventAt: fullReport.lastEventAt,
                filesScanned: fullReport.filesScanned,
                configuredShortcuts: fullReport.configuredShortcuts,
                enabledShortcuts: fullReport.enabledShortcuts,
                nativeSummary: fullReport.nativeSummary,
                shellSummary: fullReport.shellSummary,
                shortcuts: Array(fullReport.shortcuts.prefix(topLimit)),
                alerts: fullReport.alerts,
                unusedShortcuts: fullReport.unusedShortcuts
            )
        } else {
            jsonReport = fullReport
        }
        try emitJSON("stats", jsonReport)
        return
    }

    renderStatsText(
        report: fullReport,
        topLimit: topLimit ?? 15,
        showAllUnused: parsed.switches.contains("unused")
    )
}

private func renderStatsText(report: StatsReport, topLimit: Int, showAllUnused: Bool) {
    let rangeNote = formatDateSpan(firstISO: report.firstEventAt, lastISO: report.lastEventAt)
    if report.totalEvents == 0 {
        print("hotkeyd stats (window: \(report.window) · 0 fires recorded)")
        if report.filesScanned.isEmpty {
            print("  No actions.log entries found yet at \(Paths.actionLog.path).")
        } else {
            print("  No shortcut executions matched window '\(report.window)' in \(report.filesScanned.joined(separator: ", ")).")
        }
    } else {
        let okText = String(format: "%.1f%%", report.successRatePercent)
        let spanSuffix = rangeNote.map { " · \($0)" } ?? ""
        print("hotkeyd stats (window: \(report.window) · \(report.totalEvents) fire(s)\(spanSuffix) · \(okText) ok)")
        if report.nativeSummary.count > 0 {
            print("  native fast-path:  \(formatModeSummary(report.nativeSummary))")
        }
        if report.shellSummary.count > 0 {
            print("  shell scripts:     \(formatModeSummary(report.shellSummary))")
        }
    }

    if !report.shortcuts.isEmpty {
        print("")
        let visible = Array(report.shortcuts.prefix(topLimit))
        let heading = report.shortcuts.count > visible.count
            ? "TOP SHORTCUTS (showing \(visible.count) of \(report.shortcuts.count); pass --top \(report.shortcuts.count) for all)"
            : "TOP SHORTCUTS"
        print(heading)

        let keyWidth = max(10, min(18, visible.map { ($0.keys ?? "(removed)").count }.max() ?? 10))
        let nameWidth = max(12, min(22, visible.map { $0.name.count }.max() ?? 12))

        print("  \(pad("KEYS", keyWidth))  \(pad("NAME", nameWidth))  \(rpad("FIRES", 5))  \(rpad("OK", 5))  \(rpad("AVG", 7))  \(rpad("P95", 7))  \(pad("MODE", 6))  LAST USED")
        let now = Date()
        for item in visible {
            let keysCol = clip(item.keys ?? "(removed)", width: keyWidth)
            let nameCol = clip(item.name, width: nameWidth)
            let okPct = item.count > 0
                ? "\(Int((Double(item.successCount) / Double(item.count) * 100.0).rounded()))%"
                : "-"
            let avgCol = item.avgMs.map { "\($0) ms" } ?? "-"
            let p95Col = item.p95Ms.map { "\($0) ms" } ?? "-"
            let lastCol = item.lastUsedAt.flatMap { relativeAge(fromISO: $0, now: now) } ?? "-"
            print("  \(pad(keysCol, keyWidth))  \(pad(nameCol, nameWidth))  \(rpad(String(item.count), 5))  \(rpad(okPct, 5))  \(rpad(avgCol, 7))  \(rpad(p95Col, 7))  \(pad(item.executionMode, 6))  \(lastCol)")
        }
    }

    if !report.alerts.isEmpty {
        print("")
        print("ALERTS (\(report.alerts.count))")
        for alert in report.alerts {
            let keyTag = alert.keys.map { " (\($0))" } ?? ""
            print("  ! \(alert.name)\(keyTag) — \(alert.detail)")
        }
    }

    if !report.unusedShortcuts.isEmpty {
        print("")
        print("UNUSED ENABLED SHORTCUTS (\(report.unusedShortcuts.count) of \(report.enabledShortcuts) enabled had 0 fires in this window)")
        let shown = showAllUnused ? report.unusedShortcuts : Array(report.unusedShortcuts.prefix(5))
        let keyWidth = max(10, min(18, shown.map(\.keys.count).max() ?? 10))
        let nameWidth = max(12, min(22, shown.map(\.name.count).max() ?? 12))
        for item in shown {
            print("  \(pad(clip(item.keys, width: keyWidth), keyWidth))  \(pad(clip(item.name, width: nameWidth), nameWidth))  \(pad(item.executionMode, 6))  \(item.commandPreview)")
        }
        if !showAllUnused && report.unusedShortcuts.count > shown.count {
            print("  … \(report.unusedShortcuts.count - shown.count) more (run `hotkeyd stats --unused` to list all)")
        }
    }

    if !report.filesScanned.isEmpty {
        let coverage = rangeNote.map { ", \($0)" } ?? ""
        print("")
        print("Based on retained logs (\(report.filesScanned.joined(separator: ", "))\(coverage)).")
    }
}

private func formatModeSummary(_ summary: ExecutionModeStats) -> String {
    let avg = summary.avgMs.map { "\($0) ms" } ?? "-"
    let med = summary.medianMs.map { "\($0) ms" } ?? "-"
    let p95 = summary.p95Ms.map { "\($0) ms" } ?? "-"
    return "\(summary.count) fire(s) · avg \(avg) · median \(med) · p95 \(p95)"
}

private func formatDateSpan(firstISO: String?, lastISO: String?) -> String? {
    guard let firstISO, let lastISO,
          let first = parseStatsISO(firstISO),
          let last = parseStatsISO(lastISO) else {
        return nil
    }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "MMM d"
    let start = fmt.string(from: first)
    let end = fmt.string(from: last)
    return start == end ? start : "\(start) – \(end)"
}

private func relativeAge(fromISO iso: String, now: Date) -> String? {
    guard let date = parseStatsISO(iso) else { return nil }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
    return "\(seconds / 86_400)d ago"
}

private func parseStatsISO(_ raw: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: raw) { return d }
    let w = ISO8601DateFormatter()
    w.formatOptions = [.withInternetDateTime]
    return w.date(from: raw)
}

private func rpad(_ text: String, _ width: Int) -> String {
    guard text.count < width else { return text }
    return String(repeating: " ", count: width - text.count) + text
}

private func clip(_ text: String, width: Int) -> String {
    guard text.count > width else { return text }
    guard width > 1 else { return String(text.prefix(width)) }
    return String(text.prefix(width - 1)) + "…"
}
