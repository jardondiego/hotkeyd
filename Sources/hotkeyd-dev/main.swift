import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
import HotkeydCore

struct DevCLIError: Error {
    let message: String
    let code: Int32
}

struct ParsedDevArguments {
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var positionals: [String] = []
}

func parseDevBool(_ raw: String, flagName: String) throws -> Bool {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "true", "1", "yes": return true
    case "false", "0", "no": return false
    default:
        throw DevCLIError(
            message: "boolean option '--\(flagName)' expects true or false (got '\(raw)')",
            code: 2
        )
    }
}

func parseDevArguments(
    _ arguments: [String],
    valued: Set<String>,
    switches: Set<String>,
    positionals allowedPositionals: Int = 0
) throws -> ParsedDevArguments {
    let preDash = arguments.prefix(while: { $0 != "--" })
    if switches.contains("help"),
       preDash.contains(where: { arg in
           let lower = arg.lowercased()
           return lower == "--help" || lower == "-h" || lower == "--help=true" || lower == "--help=1"
       }) {
        return ParsedDevArguments(switches: ["help"])
    }

    var parsed = ParsedDevArguments()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            parsed.positionals.append(contentsOf: arguments[(index + 1)...])
            break
        }
        if argument.hasPrefix("--") {
            let body = String(argument.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0]
            if switches.contains(name) {
                if parts.count == 2 {
                    if try parseDevBool(parts[1], flagName: name) {
                        parsed.switches.insert(name)
                    } else {
                        parsed.switches.remove(name)
                    }
                } else {
                    parsed.switches.insert(name)
                }
                index += 1
                continue
            }
            guard valued.contains(name) else {
                throw DevCLIError(message: "unknown option '--\(name)'", code: 2)
            }
            let value: String
            if parts.count == 2 {
                value = parts[1]
                index += 1
            } else {
                guard index + 1 < arguments.count else {
                    throw DevCLIError(message: "option '--\(name)' needs a value", code: 2)
                }
                value = arguments[index + 1]
                index += 2
            }
            parsed.values[name] = value
            continue
        }
        if argument.hasPrefix("-") && argument != "-" {
            throw DevCLIError(message: "unknown option '\(argument)'", code: 2)
        }
        parsed.positionals.append(argument)
        index += 1
    }
    if parsed.positionals.count > allowedPositionals {
        throw DevCLIError(
            message: "unexpected argument '\(parsed.positionals[allowedPositionals])'",
            code: 2
        )
    }
    return parsed
}

func devUsage() -> String {
    """
    hotkeyd-dev — interactive keyboard diagnostic & synthetic event tool

    USAGE
      hotkeyd-dev <command> [options]

    COMMANDS
      listen [--seconds <1..30>] [--json] [--help]
             Listen to live keyboard events with human key names, Caps Lock F18 decoding,
             and live ~/.hotkeyd binding match annotations (requires interactive TTY).
      tap    [--keycode <code|name>] [--taps <1..10>] [--gap <0.02..2.0>] [--json] [--help]
             Synthesize regular key taps (default: f18 / keycode 79).
      modtap --keycode <code|mod> [--key <code|name>] [--taps <1..10>] [--gap <0.02..2.0>]
             [--hold] [--linger <0..2.0>] [--globe] [--json] [--help]
             Synthesize modifier flagsChanged taps or held modifier + key combos.

    EXAMPLES
      hotkeyd-dev listen --seconds 10
      hotkeyd-dev tap --keycode f18 --taps 2
      hotkeyd-dev modtap --keycode lcmd --taps 2
      hotkeyd-dev modtap --keycode fn --key space --hold --taps 1
    """
}

func modifierKeyCode(for raw: String) -> UInt16? {
    if let numeric = UInt16(raw) {
        return Modifier.forKeyCode(numeric) != nil ? numeric : nil
    }
    guard let mod = Modifier.parse(raw) else { return nil }
    switch mod {
    case .leftCommand, .command: return 55
    case .rightCommand: return 54
    case .leftShift, .shift: return 56
    case .rightShift: return 60
    case .leftOption, .option: return 58
    case .rightOption: return 61
    case .leftControl, .control: return 59
    case .rightControl: return 62
    case .fn: return 63
    case .capsLock: return nil
    default: return nil
    }
}

func resolveKeyCode(for raw: String) -> UInt16? {
    if let numeric = UInt16(raw) { return numeric }
    if let code = KeyCodes.code(for: raw) { return code }
    return modifierKeyCode(for: raw)
}

func warnClamped(_ flag: String, requested: String, clamped: String) {
    FileHandle.standardError.write(
        Data(("hotkeyd-dev: warning: \(flag) \(requested) clamped to \(clamped)\n").utf8)
    )
}

private struct ListenEventJSON: Encodable {
    let type: String
    let keyCode: UInt16
    let keyName: String
    let flags: UInt64
    let held: [String]
    let detectedDoubleTap: String?
    let matchedBinding: String?
}

private final class ListenSession {
    private let lock = NSLock()
    private var held = HeldModifiers()
    private var detector = DoubleTapDetector()
    private let index: BindingIndex
    private let capsRemapped: Bool
    private let jsonMode: Bool
    private let encoder = JSONEncoder()
    var tap: CFMachPort?

    init(index: BindingIndex, capsRemapped: Bool, jsonMode: Bool) {
        self.index = index
        self.capsRemapped = capsRemapped
        self.jsonMode = jsonMode
    }

    private func label(for code: UInt16) -> String {
        if capsRemapped && code == CapsLock.targetKeyCode {
            return "f18(capsLock)"
        }
        if let mod = Modifier.forKeyCode(code) {
            return mod.token
        }
        return KeyCodes.name(for: code)
    }

    private func emit(
        typeName: String,
        code: UInt16,
        flags: UInt64,
        heldTokens: [String],
        detected: String?,
        match: String?
    ) {
        let keyLabel = label(for: code)
        if jsonMode {
            let payload = ListenEventJSON(
                type: typeName,
                keyCode: code,
                keyName: keyLabel,
                flags: flags,
                held: heldTokens,
                detectedDoubleTap: detected,
                matchedBinding: match
            )
            if let data = try? encoder.encode(payload) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return
        }
        let paddedType = typeName.padding(toLength: 12, withPad: " ", startingAt: 0)
        let matchSuffix = match.map { " match=\($0)" } ?? ""
        print("\(paddedType) key=\(keyLabel)(\(code)) flags=0x\(String(flags, radix: 16)) held=[\(heldTokens.joined(separator: ","))] detected=\(detected ?? "nil")\(matchSuffix)")
        fflush(stdout)
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type != .tapDisabledByTimeout && type != .tapDisabledByUserInput && IsSecureEventInputEnabled() {
            lock.lock()
            held.reset()
            detector = DoubleTapDetector()
            lock.unlock()
            return
        }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        defer { lock.unlock() }

        switch type {
        case .flagsChanged:
            held.update(keyCode: code, flags: event.flags)
            let detected = detector.handle(.modifiers(held.keys, at: now))
            let match = detected.flatMap { index.shortcut(forGesture: $0)?.displayName }
            emit(
                typeName: "flagsChanged",
                code: code,
                flags: event.flags.rawValue,
                heldTokens: held.keys.map(\.token).sorted(),
                detected: detected?.token,
                match: match
            )
        case .keyDown:
            if capsRemapped && code == CapsLock.targetKeyCode {
                held.setCapsLock(true)
                let gestureHeld = held.keys.subtracting([.fn])
                let detected = detector.handle(.modifiers(gestureHeld, at: now))
                let match = detected.flatMap { index.shortcut(forGesture: $0)?.displayName }
                emit(
                    typeName: "keyDown",
                    code: code,
                    flags: event.flags.rawValue,
                    heldTokens: held.keys.map(\.token).sorted(),
                    detected: detected?.token,
                    match: match
                )
            } else {
                let detected = detector.handle(.key(code: code, at: now))
                let match = index.shortcut(keyCode: code, held: held)?.displayName
                    ?? index.doubleTapShortcut(keyCode: code, held: held)?.displayName
                emit(
                    typeName: "keyDown",
                    code: code,
                    flags: event.flags.rawValue,
                    heldTokens: held.keys.map(\.token).sorted(),
                    detected: detected?.token,
                    match: match
                )
            }
        case .keyUp:
            if capsRemapped && code == CapsLock.targetKeyCode {
                held.setCapsLock(false)
                let gestureHeld = held.keys.subtracting([.fn])
                let detected = detector.handle(.modifiers(gestureHeld, at: now))
                let match = detected.flatMap { index.shortcut(forGesture: $0)?.displayName }
                emit(
                    typeName: "keyUp",
                    code: code,
                    flags: event.flags.rawValue,
                    heldTokens: held.keys.map(\.token).sorted(),
                    detected: detected?.token,
                    match: match
                )
            } else {
                emit(
                    typeName: "keyUp",
                    code: code,
                    flags: event.flags.rawValue,
                    heldTokens: held.keys.map(\.token).sorted(),
                    detected: nil,
                    match: nil
                )
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if !jsonMode {
                print("tap disabled (\(type == .tapDisabledByUserInput ? "user input" : "timeout")); re-enabling")
                fflush(stdout)
            }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        default:
            break
        }
    }
}

private func listenCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let session = Unmanaged<ListenSession>.fromOpaque(refcon).takeUnretainedValue()
    session.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

func requireInteractiveTTY() throws {
    guard isatty(STDIN_FILENO) == 1
        && isatty(STDOUT_FILENO) == 1
        && isatty(STDERR_FILENO) == 1 else {
        throw DevCLIError(
            message: "hotkeyd-dev requires an interactive terminal (stdin, stdout, and stderr must be a TTY)",
            code: 2
        )
    }
    let foregroundPgrp = tcgetpgrp(STDIN_FILENO)
    guard foregroundPgrp > 0 && foregroundPgrp == getpgrp() else {
        throw DevCLIError(
            message: "hotkeyd-dev must run as the foreground process group of an interactive terminal",
            code: 2
        )
    }
}

func commandListen(_ arguments: [String]) throws {
    let parsed = try parseDevArguments(arguments, valued: ["seconds"], switches: ["json", "help"])
    if parsed.switches.contains("help") {
        print("usage: hotkeyd-dev listen [--seconds <1..30>] [--json]")
        print("Listen to live keyboard events with human key names, F18 Caps Lock decoding, and ~/.hotkeyd match annotations.")
        return
    }
    try requireInteractiveTTY()

    let rawSeconds = Double(parsed.values["seconds"] ?? "15") ?? .nan
    guard rawSeconds.isFinite else {
        throw DevCLIError(message: "--seconds must be a finite number between 1 and 30", code: 2)
    }
    let seconds = min(30.0, max(1.0, rawSeconds))
    if seconds != rawSeconds {
        warnClamped("--seconds", requested: "\(rawSeconds)", clamped: "\(seconds)")
    }

    guard AXIsProcessTrusted() else {
        throw DevCLIError(
            message: "accessibility is not granted for this terminal/binary",
            code: 5
        )
    }

    let liveIndex: BindingIndex
    if let cfg = try? Config.load(from: Paths.config) {
        liveIndex = BindingIndex(shortcuts: cfg.shortcuts)
    } else {
        liveIndex = BindingIndex()
    }
    let capsRemapped = (CapsLock.state() == .enabled)
    let jsonMode = parsed.switches.contains("json")
    let session = ListenSession(index: liveIndex, capsRemapped: capsRemapped, jsonMode: jsonMode)

    let interesting: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    let mask = interesting.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: listenCallback,
        userInfo: Unmanaged.passUnretained(session).toOpaque()
    ) else {
        throw DevCLIError(message: "could not create the diagnostic event tap", code: 5)
    }
    session.tap = tap

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        CFMachPortInvalidate(tap)
        throw DevCLIError(message: "could not create a run loop source", code: 5)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    if !jsonMode {
        print("listening for \(Int(seconds))s (\(liveIndex.count) active shortcuts loaded); press keys now")
        fflush(stdout)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
    withExtendedLifetime(session) {
        CFRunLoopRun()
    }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    if !jsonMode {
        print("stopped")
    }
}

struct TapResultJSON: Encodable {
    let ok = true
    let command: String
    let keyCode: UInt16
    let keyName: String
    let taps: Int
    let gapMilliseconds: Int
    let held: Bool
}

func emitDevJSON<T: Encodable>(_ payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func commandModifierTapTest(_ arguments: [String]) throws {
    let parsed = try parseDevArguments(
        arguments,
        valued: ["keycode", "gap", "taps", "key", "linger"],
        switches: ["json", "globe", "hold", "help"]
    )
    if parsed.switches.contains("help") {
        print("usage: hotkeyd-dev modtap --keycode <code|lcmd|rcmd|lopt|ropt|lctrl|rctrl|lshift|rshift|fn> [--key <code|name>] [--taps <1..10>] [--gap <0.02..2.0>] [--hold] [--linger <0..2.0>] [--globe] [--json]")
        return
    }
    try requireInteractiveTTY()

    guard let rawMod = parsed.values["keycode"], let keyCode = modifierKeyCode(for: rawMod),
          let modifier = Modifier.forKeyCode(keyCode) else {
        throw DevCLIError(
            message: "--keycode is required and must be a modifier name (lcmd, rcmd, fn, ...) or modifier keycode",
            code: 2
        )
    }

    let resolvedSubKey: UInt16?
    if let rawKey = parsed.values["key"] {
        guard let k = resolveKeyCode(for: rawKey) else {
            throw DevCLIError(message: "unknown --key '\(rawKey)'", code: 2)
        }
        resolvedSubKey = k
    } else {
        resolvedSubKey = nil
    }

    let rawTaps = Int(parsed.values["taps"] ?? "2") ?? -1
    guard rawTaps > 0 else {
        throw DevCLIError(message: "--taps must be an integer between 1 and 10", code: 2)
    }
    let taps = min(10, max(1, rawTaps))
    if taps != rawTaps {
        warnClamped("--taps", requested: "\(rawTaps)", clamped: "\(taps)")
    }

    let rawGap = Double(parsed.values["gap"] ?? "0.12") ?? .nan
    guard rawGap.isFinite else {
        throw DevCLIError(message: "--gap must be a finite number", code: 2)
    }
    let gap = min(2.0, max(0.02, rawGap))
    if gap != rawGap {
        warnClamped("--gap", requested: "\(rawGap)", clamped: "\(gap)")
    }

    func post(down: Bool) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = down ? modifier.cgFlag : []
        event.post(tap: .cghidEventTap)
    }

    func postKey() {
        guard let code = resolvedSubKey else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(source: nil) else { continue }
            event.type = isDown ? .keyDown : .keyUp
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            event.flags = modifier.cgFlag
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    func postGlobeKey() {
        guard parsed.switches.contains("globe") else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(source: nil) else { continue }
            event.type = isDown ? .keyDown : .keyUp
            event.setIntegerValueField(.keyboardEventKeycode, value: 179)
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    let isHold = parsed.switches.contains("hold")
    if isHold {
        post(down: true)
        Thread.sleep(forTimeInterval: 0.06)
        for index in 0..<taps {
            if index > 0 {
                Thread.sleep(forTimeInterval: gap)
            }
            postKey()
        }
        if let rawLingerText = parsed.values["linger"] {
            guard let rawLinger = Double(rawLingerText), rawLinger.isFinite else {
                throw DevCLIError(message: "--linger must be a finite number", code: 2)
            }
            let linger = min(2.0, max(0.0, rawLinger))
            if linger != rawLinger {
                warnClamped("--linger", requested: "\(rawLinger)", clamped: "\(linger)")
            }
            Thread.sleep(forTimeInterval: linger)
        }
        post(down: false)
        postGlobeKey()
    } else {
        for index in 0..<taps {
            if index > 0 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            post(down: true)
            Thread.sleep(forTimeInterval: 0.06)
            postKey()
            post(down: false)
            postGlobeKey()
            Thread.sleep(forTimeInterval: gap)
        }
    }

    if parsed.switches.contains("json") {
        try emitDevJSON(TapResultJSON(
            command: "modtap",
            keyCode: keyCode,
            keyName: modifier.token,
            taps: taps,
            gapMilliseconds: Int(gap * 1000),
            held: isHold
        ))
    } else if isHold {
        print("posted \(taps) key tap(s) while holding \(modifier.token)")
    } else {
        print("posted \(taps) \(modifier.token) tap(s) via flagsChanged")
    }
}

func commandTapTest(_ arguments: [String]) throws {
    let parsed = try parseDevArguments(
        arguments,
        valued: ["keycode", "gap", "taps"],
        switches: ["json", "help"]
    )
    if parsed.switches.contains("help") {
        print("usage: hotkeyd-dev tap [--keycode <code|name>] [--taps <1..10>] [--gap <0.02..2.0>] [--json]")
        return
    }
    try requireInteractiveTTY()

    let rawCode = parsed.values["keycode"] ?? "f18"
    guard let code = resolveKeyCode(for: rawCode) else {
        throw DevCLIError(message: "unknown --keycode '\(rawCode)' (expected a key name like f18/space or numeric keycode)", code: 2)
    }
    let rawGap = Double(parsed.values["gap"] ?? "0.12") ?? .nan
    guard rawGap.isFinite else {
        throw DevCLIError(message: "--gap must be a finite number", code: 2)
    }
    let gap = min(2.0, max(0.02, rawGap))
    if gap != rawGap {
        warnClamped("--gap", requested: "\(rawGap)", clamped: "\(gap)")
    }
    let rawTaps = Int(parsed.values["taps"] ?? "2") ?? -1
    guard rawTaps > 0 else {
        throw DevCLIError(message: "--taps must be an integer between 1 and 10", code: 2)
    }
    let taps = min(10, max(1, rawTaps))
    if taps != rawTaps {
        warnClamped("--taps", requested: "\(rawTaps)", clamped: "\(taps)")
    }

    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw DevCLIError(message: "could not create an event source", code: 8)
    }

    func tap() {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            down.flags = []
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.06)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }

    for index in 0..<taps {
        if index > 0 {
            Thread.sleep(forTimeInterval: gap)
        }
        tap()
    }
    Thread.sleep(forTimeInterval: 0.6)
    let keyName = KeyCodes.name(for: code)
    if parsed.switches.contains("json") {
        try emitDevJSON(TapResultJSON(
            command: "tap",
            keyCode: code,
            keyName: keyName,
            taps: taps,
            gapMilliseconds: Int(gap * 1000),
            held: false
        ))
    } else {
        print("posted \(taps) tap(s) of \(keyName) (keycode \(code)) with \(Int(gap * 1000)) ms gap")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    guard let cmd = arguments.first else {
        print(devUsage())
        exit(0)
    }
    let rest = Array(arguments.dropFirst())
    switch cmd {
    case "help", "--help", "-h":
        print(devUsage())
    case "listen", "__listen":
        try commandListen(rest)
    case "tap", "__tap":
        try commandTapTest(rest)
    case "modtap", "__modtap":
        try commandModifierTapTest(rest)
    default:
        throw DevCLIError(message: "unknown command '\(cmd)' (run `hotkeyd-dev --help`)", code: 2)
    }
} catch let error as DevCLIError {
    FileHandle.standardError.write(Data(("hotkeyd-dev: \(error.message)\n").utf8))
    exit(error.code)
} catch {
    FileHandle.standardError.write(Data(("hotkeyd-dev: \(error.localizedDescription)\n").utf8))
    exit(1)
}
