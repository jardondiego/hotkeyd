import Foundation
import HotkeydCore

struct PausePayload: Encodable {
    let paused: Bool
    let toggled: Bool
    let alreadyInState: Bool
    let pausedAt: String?
    let resumeAt: String?
    let remainingSeconds: Int?
    let reason: String?
    let daemonSignaled: Bool
    let sandboxed: Bool
}

func commandPause(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: ["for", "reason"],
        switches: ["toggle", "json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["pause"])
        return
    }

    let toggle = parsed.switches.contains("toggle")
    let sandboxed = Paths.isEnvironmentOverrideActive

    if toggle, PauseState.loadActive(from: Paths.pauseState, pruneExpired: true) != nil {
        try performResume(toggled: true, jsonMode: wantsJSON(parsed), sandboxed: sandboxed)
        return
    }

    let durationSeconds: TimeInterval?
    if let rawFor = parsed.values["for"] {
        guard let seconds = PauseState.parseDurationSeconds(rawFor) else {
            throw CLIError(
                message: "invalid --for duration '\(rawFor)' (expected e.g. 30s, 15m, 1h, 1h30m; range 5s..24h)",
                code: 2,
                hint: "example: hotkeyd pause --for 15m"
            )
        }
        durationSeconds = seconds
    } else {
        durationSeconds = nil
    }

    let reason = parsed.values["reason"]
    let now = Date()
    let state = PauseState(pausedAtDate: now, durationSeconds: durationSeconds, reason: reason)

    do {
        try state.save(to: Paths.pauseState)
    } catch {
        throw CLIError(
            message: "could not save pause state: \(error.localizedDescription)",
            code: 7,
            kind: "config_io"
        )
    }

    let signaled = signalDaemonForPauseChange(sandboxed: sandboxed)
    let remaining = state.remainingSeconds(at: now)
    let payload = PausePayload(
        paused: true,
        toggled: toggle,
        alreadyInState: false,
        pausedAt: state.pausedAt,
        resumeAt: state.resumeAt,
        remainingSeconds: remaining,
        reason: state.reason,
        daemonSignaled: signaled,
        sandboxed: sandboxed
    )

    if wantsJSON(parsed) {
        try emitJSON("pause", payload)
        return
    }

    var summary: String
    if let formatted = state.formattedRemaining(at: now) {
        let localTime = state.resumeDate.map { formatLocalTime($0) } ?? ""
        let timeNote = localTime.isEmpty ? "" : " (auto-resumes at \(localTime))"
        summary = "✓ Shortcuts paused for \(formatted)\(timeNote)."
    } else {
        summary = "✓ Shortcuts paused until you run `hotkeyd resume`."
    }
    if let cleanReason = state.reason {
        summary += " Reason: \(cleanReason)."
    }
    print(summary)
    if !sandboxed && !signaled {
        print("  note: daemon is not running right now; pause state will apply when it starts")
    }
}

func commandResume(_ arguments: [String]) throws {
    let parsed = try parseArguments(
        arguments,
        valued: [],
        switches: ["json", "help"],
        positionals: 0
    )
    if parsed.switches.contains("help") {
        printCommandHelp(["resume"])
        return
    }
    try performResume(
        toggled: false,
        jsonMode: wantsJSON(parsed),
        sandboxed: Paths.isEnvironmentOverrideActive
    )
}

private func performResume(toggled: Bool, jsonMode: Bool, sandboxed: Bool) throws {
    let wasPaused = PauseState.loadActive(from: Paths.pauseState, pruneExpired: true) != nil
    PauseState.clear(at: Paths.pauseState)
    let signaled = signalDaemonForPauseChange(sandboxed: sandboxed)

    let payload = PausePayload(
        paused: false,
        toggled: toggled,
        alreadyInState: !wasPaused,
        pausedAt: nil,
        resumeAt: nil,
        remainingSeconds: nil,
        reason: nil,
        daemonSignaled: signaled,
        sandboxed: sandboxed
    )

    if jsonMode {
        try emitJSON(toggled ? "pause" : "resume", payload)
        return
    }

    if wasPaused {
        print("✓ Shortcuts resumed.")
    } else {
        print("Shortcuts are already active.")
    }
}

private func signalDaemonForPauseChange(sandboxed: Bool) -> Bool {
    guard !sandboxed else { return false }
    guard LaunchAgent.isLoaded(), LaunchAgent.pid() != nil else { return false }
    notifyDaemonToReload()
    return true
}

private func formatLocalTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
