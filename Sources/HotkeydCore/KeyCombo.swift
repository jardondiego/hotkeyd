import Foundation

/// An exact key + modifier pair, e.g. `cmd+shift+c`.
///
/// Storage is by virtual key code because that is what the event tap reports; the canonical
/// string is only for humans, agents and JSON. Parsing and rendering are inverses.
public struct KeyCombo: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: Set<Modifier>

    public init(keyCode: UInt16, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var keyName: String {
        KeyCodes.name(for: keyCode)
    }

    private static let modifierOrder: [Modifier] = [
        .leftCommand, .rightCommand, .command,
        .leftOption, .rightOption, .option,
        .leftControl, .rightControl, .control,
        .leftShift, .rightShift, .shift,
        .fn, .capsLock
    ]

    /// `cmd+opt+ctrl+shift+fn+capsLock+k` — modifiers in a fixed order so round-trips are exact.
    public var canonical: String {
        let modifiersText = KeyCombo.modifierOrder
            .filter { modifiers.contains($0) }
            .map(\.token)
            .joined(separator: "+")
        return modifiersText.isEmpty ? keyName : "\(modifiersText)+\(keyName)"
    }

    public var sideSpecificity: Int {
        modifiers.filter(\.isSideSpecific).count
    }

    public func matches(keyCode: UInt16, held: HeldModifiers) -> Bool {
        self.keyCode == keyCode && held.matches(modifiers)
    }

    /// Returns `true` when `self` and `other` have the same key code, the same modifier families,
    /// equal non-zero side specificity, and can both match the same physical held state (e.g.,
    /// `lcmd+opt+C` and `cmd+lopt+C` when `lcmd+lopt+C` is held).
    public func overlapsAmbiguously(with other: KeyCombo) -> Bool {
        guard keyCode == other.keyCode, self != other else { return false }
        let familiesA = Set(modifiers.map(\.family))
        let familiesB = Set(other.modifiers.map(\.family))
        guard familiesA == familiesB else { return false }
        guard sideSpecificity == other.sideSpecificity, sideSpecificity > 0 else { return false }

        for family in familiesA {
            let sideA = modifiers.first(where: { $0.family == family })?.side
            let sideB = other.modifiers.first(where: { $0.family == family })?.side
            if let sideA, let sideB, sideA != sideB {
                return false
            }
        }
        return true
    }

    // MARK: - Parsing

    public static func parse(_ raw: String) throws -> KeyCombo {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KeyComboError.empty }

        let parts = trimmed
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count >= 2 else {
            if let code = KeyCodes.code(for: trimmed) {
                if KeyCodes.isFunctionKey(code) {
                    return KeyCombo(keyCode: code, modifiers: [])
                }
                throw KeyComboError.missingModifier(KeyCodes.name(for: code))
            }
            if Modifier.parse(trimmed) != nil {
                throw KeyComboError.missingKey
            }
            throw KeyComboError.unknownKey(trimmed)
        }
        guard let keyToken = parts.last, !keyToken.isEmpty else { throw KeyComboError.missingKey }

        var parsedModifiers: [Modifier] = []
        for token in parts.dropLast() {
            guard let modifier = Modifier.parse(token) else {
                throw KeyComboError.unknownToken(token)
            }
            if parsedModifiers.contains(modifier) {
                throw KeyComboError.duplicateModifier(modifier.token)
            }
            if parsedModifiers.contains(where: { $0.family == modifier.family }) {
                throw KeyComboError.conflictingModifier(modifier.token)
            }
            parsedModifiers.append(modifier)
        }
        let modifiers = Set(parsedModifiers)

        guard let keyCode = KeyCodes.code(for: keyToken) else {
            throw KeyComboError.unknownKey(keyToken)
        }
        if modifiers.isEmpty && !KeyCodes.isFunctionKey(keyCode) {
            throw KeyComboError.missingModifier(KeyCodes.name(for: keyCode))
        }

        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        if let reason = combo.reservedReason {
            throw KeyComboError.reserved(combo.canonical, reason)
        }
        return combo
    }

    /// Documented reserved combinations exported to `CommandRegistry` so CLI/agent discovery stays in sync.
    public static let reservedDescriptions: [(keys: String, reason: String)] = [
        ("cmd+q", "quits the front app"),
        ("cmd+tab", "switches apps"),
        ("cmd+`", "cycles windows"),
        ("cmd+space", "Spotlight (lcmd+space or rcmd+space is allowed)"),
        ("cmd+opt+escape", "Force Quit"),
        ("ctrl+cmd+q", "locks the screen"),
        ("cmd+shift+q", "logs out of macOS"),
        ("shift+<non-function key>", "breaks normal typing"),
        ("ctrl+f1/f2/f3", "Mission Control, App Windows and Launchpad"),
        ("shift > <key>", "unsided shift sequence leader conflicts with normal typing (use lshift or rshift)")
    ]

    /// Combinations we refuse to take, because losing them can lock a user out of recovery.
    public var reservedReason: String? {
        // Reserved checks are side-agnostic: lcmd+q is still cmd+q as far as macOS cares.
        let families = Set(modifiers.map(\.family))
        if families == [.command] {
            switch keyCode {
            case KeyCodes.code(for: "q"): return "cmd+q quits the front app"
            case KeyCodes.code(for: "tab"): return "cmd+tab switches apps"
            case KeyCodes.code(for: "`"): return "cmd+` cycles windows"
            case KeyCodes.code(for: "space"):
                // A side-specific binding (lcmd+space / rcmd+space) leaves the other Command key
                // free for Spotlight, so only the side-agnostic form is reserved.
                if modifiers.contains(where: \.isSideSpecific) { break }
                return "cmd+space is Spotlight (bind lcmd+space or rcmd+space to keep the other side for Spotlight)"
            default: break
            }
        }
        if families == [.command, .option], keyCode == KeyCodes.code(for: "escape") {
            return "cmd+opt+esc is Force Quit"
        }
        if families == [.control, .command], keyCode == KeyCodes.code(for: "q") {
            return "ctrl+cmd+q locks the screen"
        }
        if (families == [.command, .shift] || families == [.command, .shift, .option]),
           keyCode == KeyCodes.code(for: "q") {
            return "cmd+shift+q logs out of macOS"
        }
        if families == [.shift], !KeyCodes.isFunctionKey(keyCode) {
            return "shift alone on a non-function key breaks normal typing"
        }
        if families == [.control], [KeyCodes.code(for: "f1"), KeyCodes.code(for: "f2"), KeyCodes.code(for: "f3")].contains(keyCode) {
            return "ctrl+f1/f2/f3 are Mission Control, App Windows and Launchpad"
        }
        return nil
    }
}

/// A two-step modifier-then-key sequence, e.g. `fn > q` or `rcmd > space`.
///
/// Step 1 is a single bare modifier tap; step 2 is a bare non-modifier key pressed within the
/// sequence delay window with no modifiers held.
public struct KeySequence: Hashable, Sendable {
    public let leader: Modifier
    public let keyCode: UInt16

    public init(leader: Modifier, keyCode: UInt16) {
        self.leader = leader
        self.keyCode = keyCode
    }

    public var keyName: String {
        KeyCodes.name(for: keyCode)
    }

    public var canonical: String {
        "\(leader.token) > \(keyName)"
    }

    public var sideSpecificity: Int {
        leader.isSideSpecific ? 1 : 0
    }

    public static func parse(_ raw: String) throws -> KeySequence {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyComboError.empty }

        let separator: Character
        if trimmed.contains(">") {
            separator = ">"
        } else if trimmed.contains(":") {
            separator = ":"
        } else {
            throw KeySequenceError.missingSeparator
        }

        let parts = trimmed
            .split(separator: separator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count >= 2 else {
            throw KeySequenceError.missingSeparator
        }
        guard parts.count == 2 else {
            throw KeySequenceError.tooManySteps
        }

        let step1 = parts[0]
        let step2 = parts[1]
        guard !step1.isEmpty else { throw KeySequenceError.missingLeader }
        guard !step2.isEmpty else { throw KeySequenceError.missingFollower }

        if step1.contains("+") {
            throw KeySequenceError.compoundLeader(step1)
        }
        guard let leader = Modifier.parse(step1) else {
            if KeyCodes.code(for: step1) != nil {
                throw KeySequenceError.nonModifierLeader(step1)
            }
            throw KeySequenceError.unknownLeader(step1)
        }

        if step2.contains("+") {
            throw KeySequenceError.compoundFollower(step2)
        }
        if Modifier.parse(step2) != nil {
            throw KeySequenceError.modifierFollower(step2)
        }
        guard let keyCode = KeyCodes.code(for: step2) else {
            throw KeyComboError.unknownKey(step2)
        }

        if leader == .shift {
            let canonicalFollower = KeyCodes.name(for: keyCode)
            throw KeyComboError.reserved(
                "shift > \(canonicalFollower)",
                "unsided shift leader conflicts with normal typing; use lshift or rshift"
            )
        }

        return KeySequence(leader: leader, keyCode: keyCode)
    }
}

public enum KeySequenceError: LocalizedError, Equatable {
    case missingSeparator
    case tooManySteps
    case missingLeader
    case missingFollower
    case compoundLeader(String)
    case nonModifierLeader(String)
    case unknownLeader(String)
    case compoundFollower(String)
    case modifierFollower(String)

    public var errorDescription: String? {
        switch self {
        case .missingSeparator:
            return "key sequence must use '<modifier> > <key>' (or shell-safe '<modifier>:<key>'), e.g. fn > q or fn:q"
        case .tooManySteps:
            return "only two-step sequences '<modifier> > <key>' are supported"
        case .missingLeader:
            return "key sequence needs a leader modifier before '>', e.g. fn > q"
        case .missingFollower:
            return "key sequence needs a key after '>', e.g. fn > q"
        case .compoundLeader(let leader):
            return "sequence leader '\(leader)' must be a single modifier (e.g. fn, rcmd, capsLock), not a chord"
        case .nonModifierLeader(let leader):
            return "sequence leader '\(leader)' must be a modifier, not a regular key"
        case .unknownLeader(let leader):
            return "unknown sequence leader '\(leader)'; use cmd, opt, ctrl, lshift/rshift, fn or capsLock"
        case .compoundFollower(let follower):
            return "sequence follower '\(follower)' must be a bare non-modifier key without '+'"
        case .modifierFollower(let follower):
            return "sequence follower '\(follower)' must be a non-modifier key, not a modifier"
        }
    }
}

public enum KeyComboError: LocalizedError, Equatable {
    case empty
    case missingKey
    case missingModifier(String)
    case unknownToken(String)
    case unknownKey(String)
    case duplicateModifier(String)
    case conflictingModifier(String)
    case unsupportedModifier(String)
    case reserved(String, String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "key combination is empty"
        case .missingKey:
            return "key combination needs a key, e.g. cmd+shift+c"
        case .missingModifier(let key):
            return "'\(key)' needs at least one modifier (only f1-f20 may be bound bare)"
        case .unknownToken(let token):
            return "unknown modifier '\(token)'; use cmd, opt, ctrl, shift, fn or capsLock (prefix l/r for sides, e.g. lcmd, ropt)"
        case .unknownKey(let key):
            return "unknown key '\(key)'; use a-z, 0-9, f1-f20, space, return, escape, tab, arrows, or run `hotkeyd describe --json` for all keys"
        case .duplicateModifier(let token):
            return "modifier '\(token)' appears twice"
        case .conflictingModifier(let token):
            return "'\(token)' conflicts with another modifier of the same family; use either cmd or lcmd/rcmd, not both"
        case .unsupportedModifier(let name):
            return "\(name) cannot be used in a key combination; bind it as a double-tap '\(name)' or sequence leader '\(name) > <key>'"
        case .reserved(let combo, let reason):
            return "\(combo) is reserved: \(reason)"
        }
    }
}

public enum KeyCodes {
    private static let table: [(name: String, code: UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
        ("c", 8), ("v", 9), ("section", 10), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16),
        ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23),
        ("equals", 24), ("9", 25), ("7", 26), ("minus", 27), ("8", 28), ("0", 29),
        ("rightbracket", 30), ("o", 31), ("u", 32), ("leftbracket", 33), ("i", 34), ("p", 35),
        ("return", 36), ("l", 37), ("j", 38), ("quote", 39), ("k", 40), ("semicolon", 41),
        ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45), ("m", 46), ("period", 47),
        ("tab", 48), ("space", 49), ("backtick", 50), ("delete", 51), ("escape", 53),
        ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90),
        ("f5", 96), ("f6", 97), ("f7", 98), ("f3", 99), ("f8", 100), ("f9", 101),
        ("f11", 103), ("f13", 105), ("f16", 106), ("f14", 107), ("f10", 109), ("f12", 111),
        ("f15", 113), ("help", 114), ("home", 115), ("pageup", 116), ("forwarddelete", 117),
        ("f4", 118), ("end", 119), ("f2", 120), ("pagedown", 121), ("f1", 122),
        ("left", 123), ("right", 124), ("down", 125), ("up", 126)
    ]

    private static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "backspace": "delete", "del": "forwarddelete",
        "pgup": "pageup", "pgdn": "pagedown", "pagedn": "pagedown",
        "leftarrow": "left", "rightarrow": "right", "uparrow": "up", "downarrow": "down",
        "spacebar": "space", "dot": "period", "grave": "backtick", "§": "section",
        "[": "leftbracket", "]": "rightbracket", ";": "semicolon", "=": "equals",
        "-": "minus", "`": "backtick", "'": "quote", "\\": "backslash", "/": "slash",
        ",": "comma", ".": "period"
    ]

    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, // f1..f10
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90  // f11..f20
    ]

    private static let byName: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for entry in table {
            map[entry.name.lowercased()] = entry.code
        }
        for (alias, canonical) in aliases {
            map[alias] = byNameCanonical(canonical)
        }
        return map
    }()

    private static func byNameCanonical(_ canonical: String) -> UInt16? {
        table.first { $0.name.lowercased() == canonical.lowercased() }?.code
    }

    private static let byCode: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        for entry in table where map[entry.code] == nil {
            map[entry.code] = entry.name
        }
        return map
    }()

    public static var allKeyNames: [String] {
        table.map(\.name)
    }

    public static var allAliases: [String: String] {
        aliases
    }

    public static func code(for name: String) -> UInt16? {
        byName[name.lowercased()]
    }

    public static func name(for code: UInt16) -> String {
        byCode[code] ?? "key\(code)"
    }

    public static func isFunctionKey(_ code: UInt16) -> Bool {
        functionKeyCodes.contains(code)
    }
}
