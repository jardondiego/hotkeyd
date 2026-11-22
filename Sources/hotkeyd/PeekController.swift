import Darwin
import Foundation
import HotkeydCore

/// Pure peek state-machine transitions computed inside `Daemon.handle` under `Daemon.lock` and
/// executed asynchronously on `controlQueue` so the event-tap thread never blocks or performs I/O.
enum PeekEffect: Sendable, Equatable {
    case none
    case arm(trigger: Modifier, delayMilliseconds: Int, generation: UInt64)
    case cancelPending
    case updatePinned(held: Set<Modifier>)
    case hide
    case showPinned
    case toggleSearch
}

/// Manages the lazy, TCC-disclaimed UI helper subprocess (`hotkeyd __peek-overlay`) over an
/// unnamed `pipe(2)`. Uses non-blocking `DispatchSourceWrite` framing so frames above the 16 KiB
/// initial pipe buffer never truncate or corrupt NDJSON framing, and retains per-PID process exit
/// reapers until `waitpid(2)` succeeds so dead helpers never leak as zombies.
/// All methods must be called strictly on `Daemon.controlQueue`.
final class PeekOverlayBridge {
    private let binaryPath: String
    private let allowAdhoc: Bool
    private let queue: DispatchQueue

    private var helperPID: pid_t = -1
    private var writeFD: Int32 = -1
    private var writeSource: DispatchSourceWrite?
    private var writeSourceSuspended = true
    private var activeFrame: Data?
    private var activeFrameOffset: Int = 0
    private var pendingFrame: Data?
    private var allowRespawnOnInitialError = false
    private var writeStallTimer: DispatchSourceTimer?

    private var reapers: [pid_t: DispatchSourceProcess] = [:]
    private var killTimers: [pid_t: DispatchSourceTimer] = [:]
    private var recentSpawnTimes: [TimeInterval] = []
    /// Invoked on `queue` whenever the active helper exits, stalls, or tears down unexpectedly so
    /// the daemon can immediately clear phantom `.pinned` / `.hold` state.
    var onHelperExited: (() -> Void)?

    private static let maxSpawnsPerWindow = 4
    private static let spawnWindowSeconds: Double = 10.0
    private static let writeStallTimeoutSeconds: Double = 2.0
    private static let forceKillGraceSeconds: Double = 1.5

    init(binaryPath: String, allowAdhoc: Bool, queue: DispatchQueue) {
        self.binaryPath = binaryPath
        self.allowAdhoc = allowAdhoc
        self.queue = queue
    }

    deinit {
        closeActiveHelperChannel()
        for (_, source) in reapers {
            source.cancel()
        }
        reapers.removeAll()
        for (_, timer) in killTimers {
            timer.cancel()
        }
        killTimers.removeAll()
    }

    var isHelperRunning: Bool {
        helperPID > 0 && writeFD >= 0
    }

    @discardableResult
    func show(_ snapshot: PeekSnapshot) -> Bool {
        // Never spawn desktop UI during sandboxed `HOTKEYD_HOME` automated tests.
        guard !Paths.isEnvironmentOverrideActive else { return false }
        guard let frame = PeekWireMessage.show(snapshot).encodeLine() else {
            Log.daemon("peek overlay frame exceeded max size; skipping show")
            return false
        }
        return enqueueFrame(frame, allowLazyRespawn: true)
    }

    @discardableResult
    func toggleSearch(_ snapshot: PeekSearchSnapshot) -> Bool {
        guard !Paths.isEnvironmentOverrideActive else { return false }
        guard let frame = PeekWireMessage.toggleSearch(snapshot).encodeLine() else {
            Log.daemon("peek search frame exceeded max size; skipping toggleSearch")
            return false
        }
        return enqueueFrame(frame, allowLazyRespawn: true)
    }

    func hide() {
        guard isHelperRunning else { return }
        guard let frame = PeekWireMessage.hide.encodeLine() else { return }
        _ = enqueueFrame(frame, allowLazyRespawn: false)
    }

    func shutdown() {
        tearDownHelper(sendQuit: true, escalateKill: true, notifyExit: false)
    }

    // MARK: - Private helpers (controlQueue only)

    @discardableResult
    private func enqueueFrame(_ frame: Data, allowLazyRespawn: Bool) -> Bool {
        if !isHelperRunning {
            guard allowLazyRespawn, spawnHelper() else { return false }
            activeFrame = frame
            activeFrameOffset = 0
            pendingFrame = nil
            allowRespawnOnInitialError = false
            drainWriteBuffer()
            return isHelperRunning
        }

        if activeFrame == nil {
            activeFrame = frame
            activeFrameOffset = 0
            allowRespawnOnInitialError = allowLazyRespawn
            drainWriteBuffer()
            return isHelperRunning
        } else {
            // Preserve the in-flight frame to its trailing '\n' so NDJSON framing never corrupts,
            // coalescing any older queued frame behind it to the latest state.
            pendingFrame = frame
            return true
        }
    }

    private func drainWriteBuffer() {
        while let frame = activeFrame, writeFD >= 0 {
            let fd = writeFD
            var writeResult: ssize_t = -1
            var writeErrno: Int32 = 0
            frame.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress, activeFrameOffset < rawBuffer.count else {
                    writeResult = 0
                    return
                }
                writeResult = Darwin.write(fd, base.advanced(by: activeFrameOffset), rawBuffer.count - activeFrameOffset)
                writeErrno = errno
            }

            if writeResult > 0 {
                activeFrameOffset += writeResult
                if activeFrameOffset >= frame.count {
                    // Frame fully written through its trailing '\n'.
                    activeFrame = pendingFrame
                    pendingFrame = nil
                    activeFrameOffset = 0
                    allowRespawnOnInitialError = false
                    if activeFrame == nil {
                        cancelWriteStallTimer()
                        suspendWriteSource()
                        return
                    }
                } else {
                    // Partial progress made: reset stall deadline and keep draining.
                    armWriteStallTimer()
                }
                continue
            }

            if writeResult < 0 && writeErrno == EINTR {
                continue
            }

            if writeResult < 0 && (writeErrno == EAGAIN || writeErrno == EWOULDBLOCK) {
                armWriteStallTimer()
                resumeWriteSource()
                return
            }

            // Broken pipe / write error. If zero bytes of this frame were written to a stale
            // helper that exited cleanly after its idle timeout, respawn lazily once.
            if activeFrameOffset == 0 && allowRespawnOnInitialError {
                let retryFrame = pendingFrame ?? frame
                tearDownHelper(sendQuit: false, escalateKill: false, notifyExit: false)
                guard spawnHelper() else { return }
                activeFrame = retryFrame
                activeFrameOffset = 0
                pendingFrame = nil
                allowRespawnOnInitialError = false
                continue
            }

            Log.daemon("peek overlay pipe write failed mid-frame (errno \(writeErrno)); restarting helper")
            tearDownHelper(sendQuit: false, escalateKill: true, notifyExit: true)
            return
        }

        cancelWriteStallTimer()
        suspendWriteSource()
    }

    private func spawnHelper() -> Bool {
        guard !Paths.isEnvironmentOverrideActive else { return false }

        let now = ProcessInfo.processInfo.systemUptime
        recentSpawnTimes = recentSpawnTimes.filter { now - $0 < Self.spawnWindowSeconds }
        guard recentSpawnTimes.count < Self.maxSpawnsPerWindow else {
            Log.daemon("peek overlay helper spawn rate-limited; skipping")
            return false
        }
        recentSpawnTimes.append(now)

        // Close post-startup binary replacement TOCTOU before spawning and piping config snapshots.
        do {
            try StrictModes.verifySecurePath(binaryPath, expectRegularFile: true)
            _ = try CodeTrust.verify(binaryPath: binaryPath, allowAdhoc: allowAdhoc)
        } catch {
            Log.daemon("peek overlay helper spawn blocked (CodeTrust/StrictModes): \(error.localizedDescription)")
            return false
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            Log.daemon("peek overlay pipe() failed: \(String(cString: strerror(errno)))")
            return false
        }
        let readEnd = pipeFDs[0]
        let writeEnd = pipeFDs[1]
        guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writeEnd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0 else {
            close(readEnd)
            close(writeEnd)
            Log.daemon("peek overlay fcntl(FD_CLOEXEC/F_SETNOSIGPIPE) failed")
            return false
        }

        // Prevent a slow helper from ever blocking the daemon's controlQueue.
        let flags = fcntl(writeEnd, F_GETFL)
        guard flags >= 0, fcntl(writeEnd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(readEnd)
            close(writeEnd)
            Log.daemon("peek overlay fcntl(O_NONBLOCK) failed")
            return false
        }

        let env = helperEnvironment()
        let result = ShellRunner.spawnProcess(
            executablePath: binaryPath,
            arguments: [binaryPath, "__peek-overlay"],
            environment: env,
            workingDirectory: Paths.realHomeDirectory.path,
            stdinFD: readEnd,
            stdoutFD: -1,
            stderrFD: -1,
            disclaimResponsibility: true,
            setProcessGroup: true,
            inheritStandardIO: false
        )

        // Parent no longer needs the read end.
        close(readEnd)

        switch result {
        case .failure(let err):
            close(writeEnd)
            Log.daemon("peek overlay helper spawn failed (errno \(err.errnoCode)): \(String(cString: strerror(err.errnoCode)))")
            return false

        case .success(let pid):
            installExitWatcher(for: pid)
            do {
                _ = try CodeTrust.verifyRunningProcess(
                    pid: pid,
                    expectedBinaryPath: binaryPath,
                    allowAdhoc: allowAdhoc
                )
            } catch {
                close(writeEnd)
                _ = kill(pid, SIGKILL)
                Log.daemon("peek overlay helper pid \(pid) failed post-spawn CodeTrust verification; terminated: \(error.localizedDescription)")
                return false
            }
            helperPID = pid
            writeFD = writeEnd
            installWriteSource(for: writeEnd)
            Log.daemon("peek overlay helper started (pid \(pid), TCC-disclaimed)")
            return true
        }
    }

    private func installWriteSource(for fd: Int32) {
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainWriteBuffer()
        }
        source.setCancelHandler {
            close(fd)
        }
        writeSource = source
        writeSourceSuspended = true
    }

    private func resumeWriteSource() {
        guard writeSourceSuspended, let source = writeSource else { return }
        writeSourceSuspended = false
        source.resume()
    }

    private func suspendWriteSource() {
        guard !writeSourceSuspended, let source = writeSource else { return }
        writeSourceSuspended = true
        source.suspend()
    }

    private func cancelWriteSource() {
        guard let source = writeSource else {
            if writeFD >= 0 {
                close(writeFD)
            }
            return
        }
        writeSource = nil
        source.cancel()
        if writeSourceSuspended {
            writeSourceSuspended = false
            source.resume()
        }
    }

    private func armWriteStallTimer() {
        cancelWriteStallTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.writeStallTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeFrame != nil else { return }
            Log.daemon("peek overlay helper pipe write stalled for \(Self.writeStallTimeoutSeconds)s; terminating helper")
            self.tearDownHelper(sendQuit: false, escalateKill: true, notifyExit: true)
        }
        timer.resume()
        writeStallTimer = timer
    }

    private func cancelWriteStallTimer() {
        writeStallTimer?.cancel()
        writeStallTimer = nil
    }

    private func installExitWatcher(for pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.reapChild(pid)
        }
        reapers[pid] = source
        source.resume()
    }

    private func reapChild(_ pid: pid_t) {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid || (result < 0 && errno == ECHILD) else {
            return
        }
        reapers.removeValue(forKey: pid)?.cancel()
        killTimers.removeValue(forKey: pid)?.cancel()
        if helperPID == pid {
            closeActiveHelperChannel()
            Log.daemon("peek overlay helper exited (pid \(pid))")
            onHelperExited?()
        }
    }

    private func tearDownHelper(sendQuit: Bool, escalateKill: Bool, notifyExit: Bool = true) {
        let pid = helperPID
        let hadActiveHelper = isHelperRunning
        if sendQuit && isHelperRunning && activeFrame == nil && writeFD >= 0,
           let quitFrame = PeekWireMessage.quit.encodeLine() {
            quitFrame.withUnsafeBytes { rawBuffer in
                if let base = rawBuffer.baseAddress {
                    _ = Darwin.write(writeFD, base, rawBuffer.count)
                }
            }
        }
        closeActiveHelperChannel()
        if notifyExit && hadActiveHelper {
            onHelperExited?()
        }
        guard pid > 0 else { return }

        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid || (reaped < 0 && errno == ECHILD) {
            reapers.removeValue(forKey: pid)?.cancel()
            killTimers.removeValue(forKey: pid)?.cancel()
            return
        }

        // Keep `reapers[pid]` alive so the child is ALWAYS reaped once it exits on pipe EOF.
        if sendQuit || escalateKill {
            _ = kill(pid, SIGTERM)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.forceKillGraceSeconds)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.killTimers.removeValue(forKey: pid)?.cancel()
                var st: Int32 = 0
                let check = waitpid(pid, &st, WNOHANG)
                if check == 0 {
                    _ = kill(pid, SIGKILL)
                } else if check == pid || (check < 0 && errno == ECHILD) {
                    self.reapers.removeValue(forKey: pid)?.cancel()
                }
            }
            killTimers[pid]?.cancel()
            killTimers[pid] = timer
            timer.resume()
        }
    }

    private func closeActiveHelperChannel() {
        cancelWriteStallTimer()
        activeFrame = nil
        activeFrameOffset = 0
        pendingFrame = nil
        allowRespawnOnInitialError = false
        writeFD = -1
        helperPID = -1
        cancelWriteSource()
    }

    private func helperEnvironment() -> [String] {
        var env: [String] = [
            "HOME=\(Paths.realHomeDirectory.path)",
            "PATH=\(ShellRunner.privilegedPath)",
            "LANG=en_US.UTF-8"
        ]
        let user = Paths.realUserName
        if !user.isEmpty && !user.contains("\0") && !user.contains("\n") {
            env.append("USER=\(user)")
        }
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"],
           tmpdir.hasPrefix("/"),
           !tmpdir.contains("\0"),
           !tmpdir.contains("\n"),
           !tmpdir.contains("\r") {
            env.append("TMPDIR=\(tmpdir)")
        }
        return env
    }
}
