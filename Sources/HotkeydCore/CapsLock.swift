import Darwin
import Foundation
import IOKit
import IOKit.hidsystem

/// Caps Lock cannot be intercepted usefully by an event tap: macOS toggles the caps state below
/// the tap, so "swallowing" it still flips the LED. The honest fix is a HID-level remap to F18,
/// which the tap can then see, swallow and treat as a double-tappable key.
///
/// We only ever own a mapping that is exactly ours. If another tool set one, we refuse to touch
/// it rather than clobbering its configuration.
public enum CapsLock {
    public static let sourceUsage: UInt64 = 0x700000039 // Caps Lock
    public static let targetUsage: UInt64 = 0x70000006D // F18
    public static let targetKeyCode: UInt16 = 79       // F18 virtual key code

    public enum State: Equatable, Sendable {
        case off
        case enabled
        case foreign(String)
    }

    public enum CapsError: LocalizedError, Equatable {
        case foreignMapping(String)
        case commandFailed(String)
        case capsLockStuck

        public var errorDescription: String? {
            switch self {
            case .foreignMapping(let detail):
                return "another tool already remaps keys (\(detail)); refusing to overwrite it"
            case .commandFailed(let output):
                return "hidutil failed: \(output)"
            case .capsLockStuck:
                return "Caps Lock is on and could not be cleared; turn it off before enabling the remap"
            }
        }
    }

    /// The exact property payload we write. Exposed for tests.
    public static var payload: String {
        "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(sourceUsage),"
            + "\"HIDKeyboardModifierMappingDst\":\(targetUsage)}]}"
    }

    public static func state() -> State {
        let result = runHidutil(["property", "--get", "UserKeyMapping"])
        let output = result.output
        guard result.status == 0 else {
            return .foreign(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parseMappingOutput(output)
    }

    /// Parses `hidutil property --get UserKeyMapping` output, failing closed to `.foreign` on
    /// quoted-hex foreign mappings or malformed non-empty mapping blocks.
    public static func parseMappingOutput(_ output: String) -> State {
        var sources: [UInt64] = []
        var targets: [UInt64] = []
        var sawMappingKey = false
        var parseFailed = false

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("HIDKeyboardModifierMappingSrc") {
                sawMappingKey = true
                if let value = number(afterEquals: line) {
                    sources.append(value)
                } else {
                    parseFailed = true
                }
            } else if line.hasPrefix("HIDKeyboardModifierMappingDst") {
                sawMappingKey = true
                if let value = number(afterEquals: line) {
                    targets.append(value)
                } else {
                    parseFailed = true
                }
            } else if line.contains("HIDKeyboardModifierMapping") {
                sawMappingKey = true
            }
        }

        if parseFailed || sources.count != targets.count || (sawMappingKey && sources.isEmpty) {
            return .foreign("unrecognized UserKeyMapping format")
        }

        let pairs = zip(sources, targets).map { Pair(source: $0, target: $1) }
        if pairs.isEmpty {
            let compact = output.components(separatedBy: .whitespacesAndNewlines).joined()
            if compact.isEmpty || compact == "(null)" || compact == "()" || compact == "[]" {
                return .off
            }
            return .foreign("unrecognized UserKeyMapping format")
        }
        if pairs.count == 1, pairs[0].source == sourceUsage, pairs[0].target == targetUsage {
            return .enabled
        }
        let detail = pairs
            .map { "0x\(String($0.source, radix: 16)) -> 0x\(String($0.target, radix: 16))" }
            .joined(separator: ", ")
        return .foreign(detail)
    }

    public static func enable(forceReapply: Bool = false) throws {
        // A caps state of ON while the key is remapped is unrecoverable from the keyboard: the
        // key no longer toggles it. Clear the state before taking the key away, and refuse to
        // remap if it cannot be cleared.
        guard ensureCapsLockOff() else {
            throw CapsError.capsLockStuck
        }

        switch state() {
        case .enabled:
            guard forceReapply else { return }
            let result = runHidutil(["property", "--set", payload])
            guard result.status == 0 else {
                throw CapsError.commandFailed(result.output)
            }
            guard ensureCapsLockOff() else {
                try? disable()
                throw CapsError.capsLockStuck
            }
            return
        case .foreign(let detail):
            throw CapsError.foreignMapping(detail)
        case .off:
            let result = runHidutil(["property", "--set", payload])
            guard result.status == 0 else {
                throw CapsError.commandFailed(result.output)
            }
            guard state() == .enabled else {
                // Never leave the keyboard remapped but unrecognised: that would cost the user
                // their Caps Lock key without giving them the gesture.
                _ = runHidutil(["property", "--set", "{\"UserKeyMapping\":[]}"])
                throw CapsError.commandFailed("mapping did not stick")
            }
            // Defensive: if the state flipped during the remap, put it back.
            guard ensureCapsLockOff() else {
                try? disable()
                throw CapsError.capsLockStuck
            }
        }
    }

    public static func disable() throws {
        guard state() == .enabled else { return }
        let result = runHidutil(["property", "--set", "{\"UserKeyMapping\":[]}"])
        guard result.status == 0 else {
            throw CapsError.commandFailed(result.output)
        }
    }

    // MARK: - Caps state (pure Swift IOKit)
    //
    // `hidutil` remaps the key; it says nothing about the caps *state*, which lives in
    // IOHIDSystem. `CGEventSource.flagsState` is not authoritative (it can report off while the
    // keyboard types uppercase), so state goes through IOHIDGet/SetModifierLockState.

    public struct IOKitError: Error, Equatable {
        public let code: kern_return_t
        public init(_ code: kern_return_t) { self.code = code }
    }

    /// Reads the authoritative Caps Lock state from `IOHIDSystem`, returning `.failure(IOKitError)`
    /// if the IOKit service cannot be opened or queried.
    public static func readCapsLockState() -> Result<Bool, IOKitError> {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != 0 else {
            return .failure(IOKitError(KERN_FAILURE))
        }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openStatus = IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &connect
        )
        guard openStatus == KERN_SUCCESS, connect != 0 else {
            return .failure(IOKitError(openStatus == KERN_SUCCESS ? KERN_FAILURE : openStatus))
        }
        defer { IOServiceClose(connect) }

        var state = false
        let getStatus = IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        guard getStatus == KERN_SUCCESS else {
            return .failure(IOKitError(getStatus))
        }
        return .success(state)
    }

    /// Sets the authoritative Caps Lock state in `IOHIDSystem`.
    @discardableResult
    public static func setCapsLockState(_ on: Bool) -> kern_return_t {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != 0 else {
            return KERN_FAILURE
        }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openStatus = IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &connect
        )
        guard openStatus == KERN_SUCCESS, connect != 0 else {
            return openStatus == KERN_SUCCESS ? KERN_FAILURE : openStatus
        }
        defer { IOServiceClose(connect) }

        return IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }

    public static func isCapsLockOn() -> Bool {
        if case .success(let isOn) = readCapsLockState() {
            return isOn
        }
        return false
    }

    /// Forces Caps Lock off and verifies the state is confirmed off by IOHIDSystem (failing
    /// closed if IOKit queries fail).
    @discardableResult
    public static func ensureCapsLockOff(attempts: Int = 3) -> Bool {
        for _ in 0..<max(1, attempts) {
            _ = setCapsLockState(false)
            if case .success(false) = readCapsLockState() {
                return true
            }
            usleep(50_000)
        }
        if case .success(false) = readCapsLockState() {
            return true
        }
        return false
    }

    // MARK: - Parsing

    private struct Pair {
        let source: UInt64
        let target: UInt64
    }

    public static func number(afterEquals line: String) -> UInt64? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";,\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("0x") {
            return UInt64(raw.dropFirst(2), radix: 16)
        }
        return UInt64(raw)
    }

    private static func runHidutil(_ arguments: [String]) -> (status: Int32, output: String) {
        let result = ShellRunner.runSystemTool(
            executablePath: "/usr/bin/hidutil",
            arguments: ["/usr/bin/hidutil"] + arguments,
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
        return (result.timedOut ? -1 : result.exitCode, combined)
    }
}
