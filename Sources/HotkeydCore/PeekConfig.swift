import Foundation

/// Configuration for the opt-in hold-modifier peek overlay and Spotlight Search HUD (`hotkeyd peek`).
///
/// Stored as an optional top-level `"peek"` object in `~/.hotkeyd` and omitted on save whenever
/// all fields match defaults so existing configs stay untouched.
public struct PeekConfig: Codable, Sendable, Equatable {
    public static let defaultDelayMilliseconds: Int = 450
    /// Strictly above `DoubleTapDetector` / `SequenceDetector`'s 250 ms `tapMax` so normal taps
    /// and `fn > key` sequences never accidentally flash the overlay.
    public static let minDelayMilliseconds: Int = 300
    public static let maxDelayMilliseconds: Int = 2_000
    public static let defaultTriggers: [Modifier] = [.fn]
    public static let `default` = PeekConfig()

    public var enabled: Bool
    public var triggers: [Modifier]
    public var delayMilliseconds: Int
    public var toggle: KeyTarget?
    public var searchToggle: KeyTarget?
    public var showDisabled: Bool
    public var dimUnmatched: Bool

    public init(
        enabled: Bool = false,
        triggers: [Modifier] = PeekConfig.defaultTriggers,
        delayMilliseconds: Int = PeekConfig.defaultDelayMilliseconds,
        toggle: KeyTarget? = nil,
        searchToggle: KeyTarget? = nil,
        showDisabled: Bool = false,
        dimUnmatched: Bool = true
    ) {
        self.enabled = enabled
        self.triggers = triggers
        self.delayMilliseconds = delayMilliseconds
        self.toggle = toggle
        self.searchToggle = searchToggle
        self.showDisabled = showDisabled
        self.dimUnmatched = dimUnmatched
    }

    public var isDefault: Bool {
        self == .default
    }

    /// Triggers active in the daemon right now. `capsLock` only participates when Caps Lock is
    /// already remapped for at least one enabled `capsLock` shortcut so hardware Caps Lock is
    /// never hijacked unexpectedly.
    public func activeTriggers(capsLockRemapped: Bool) -> [Modifier] {
        guard enabled else { return [] }
        return triggers.filter { trigger in
            trigger != .capsLock || capsLockRemapped
        }
    }

    /// Returns `true` when `modifier` (a physical held modifier key) satisfies any active trigger.
    public func matchesTrigger(_ modifier: Modifier, capsLockRemapped: Bool) -> Bool {
        for trigger in activeTriggers(capsLockRemapped: capsLockRemapped) {
            if trigger == modifier {
                return true
            }
            if trigger.side == nil && trigger.family == modifier.family {
                return true
            }
        }
        return false
    }

    /// Returns `true` when `capsLock` is configured in `triggers` but inactive because no enabled
    /// `capsLock` shortcut exists in `~/.hotkeyd`.
    public func isCapsLockTriggerDormant(hasCapsLockBinding: Bool) -> Bool {
        enabled && triggers.contains(.capsLock) && !hasCapsLockBinding
    }

    /// Parses a comma-separated list of modifier tokens (e.g. `"fn,capsLock"`, `"lcmd"`, or `"none"`).
    public static func parseTriggerList(_ raw: String) throws -> [Modifier] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "none" {
            return []
        }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [Modifier] = []
        var seen: Set<Modifier> = []
        var seenFamilies: [Modifier.Family: [Modifier]] = [:]
        for part in parts {
            guard !part.isEmpty else {
                throw ConfigError.malformed("peek triggers list contains an empty entry")
            }
            guard let mod = Modifier.parse(part) else {
                throw ConfigError.malformed(
                    "unknown peek trigger modifier '\(part)'; expected fn, capsLock, cmd/lcmd/rcmd, opt/lopt/ropt, ctrl/lctrl/rctrl, or shift/lshift/rshift"
                )
            }
            guard seen.insert(mod).inserted else {
                throw ConfigError.duplicatePeekTrigger(mod.token)
            }
            if let existing = seenFamilies[mod.family] {
                for other in existing where other.side == nil || mod.side == nil {
                    throw ConfigError.duplicatePeekTrigger("\(other.token) / \(mod.token)")
                }
            }
            seenFamilies[mod.family, default: []].append(mod)
            result.append(mod)
        }
        return result
    }

    public func validate(against shortcuts: [Shortcut], hasCapsLockRemap: Bool) throws {
        guard (Self.minDelayMilliseconds...Self.maxDelayMilliseconds).contains(delayMilliseconds) else {
            throw ConfigError.invalidPeekDelay(delayMilliseconds)
        }

        var seen: Set<Modifier> = []
        var seenFamilies: [Modifier.Family: [Modifier]] = [:]
        for trigger in triggers {
            guard seen.insert(trigger).inserted else {
                throw ConfigError.duplicatePeekTrigger(trigger.token)
            }
            if let existing = seenFamilies[trigger.family] {
                for other in existing where other.side == nil || trigger.side == nil {
                    throw ConfigError.duplicatePeekTrigger("\(other.token) / \(trigger.token)")
                }
            }
            seenFamilies[trigger.family, default: []].append(trigger)
        }

        if let toggle {
            try Self.validateToggleTarget(
                toggle,
                fieldName: "peek.toggle",
                shortcuts: shortcuts,
                hasCapsLockRemap: hasCapsLockRemap
            )
        }
        if let searchToggle {
            try Self.validateToggleTarget(
                searchToggle,
                fieldName: "peek.searchToggle",
                shortcuts: shortcuts,
                hasCapsLockRemap: hasCapsLockRemap
            )
        }
        if let toggle, let searchToggle {
            if toggle == searchToggle {
                throw ConfigError.conflictingPeekToggle(
                    field: "peek.searchToggle",
                    keys: searchToggle.canonical,
                    target: "peek.toggle"
                )
            }
            if Self.targetsOverlap(toggle, searchToggle) {
                throw ConfigError.ambiguousPeekToggle(
                    field: "peek.searchToggle",
                    keys: searchToggle.canonical,
                    target: "peek.toggle '\(toggle.canonical)'"
                )
            }
        }
    }

    /// Symmetric overlap predicate across exact and unsided-vs-sided `KeyTarget` pairs. Because
    /// `Daemon.handle` evaluates `peek.toggle` and `peek.searchToggle` ahead of `BindingIndex`,
    /// any compatible unsided/sided overlap (e.g. `cmd` vs `lcmd`, `cmd > s` vs `lcmd > s`, or
    /// `cmd+k` vs `lcmd+k`) would silently hijack the other binding unless rejected here.
    public static func targetsOverlap(_ a: KeyTarget, _ b: KeyTarget) -> Bool {
        func modifiersOverlap(_ m1: Modifier, _ m2: Modifier) -> Bool {
            m1.family == m2.family && (m1.side == nil || m2.side == nil || m1.side == m2.side)
        }

        switch (a, b) {
        case (.modifier(let m1), .modifier(let m2)):
            return modifiersOverlap(m1, m2)

        case (.sequence(let s1), .sequence(let s2)):
            return s1.keyCode == s2.keyCode && modifiersOverlap(s1.leader, s2.leader)

        case (.combo(let c1), .combo(let c2)):
            guard c1.keyCode == c2.keyCode else { return false }
            let families1 = Set(c1.modifiers.map(\.family))
            let families2 = Set(c2.modifiers.map(\.family))
            guard families1 == families2 else { return false }
            for family in families1 {
                let side1 = c1.modifiers.first(where: { $0.family == family })?.side
                let side2 = c2.modifiers.first(where: { $0.family == family })?.side
                if let side1, let side2, side1 != side2 {
                    return false
                }
            }
            return true

        default:
            return false
        }
    }

    private static func validateToggleTarget(
        _ target: KeyTarget,
        fieldName: String,
        shortcuts: [Shortcut],
        hasCapsLockRemap: Bool
    ) throws {
        switch target {
        case .combo(let combo):
            if let reason = combo.reservedReason {
                throw ConfigError.malformed("\(fieldName) '\(combo.canonical)' is reserved (\(reason))")
            }
            if hasCapsLockRemap && combo.keyCode == CapsLock.targetKeyCode {
                throw ConfigError.conflictingCapsLockF18(fieldName)
            }
            for shortcut in shortcuts where shortcut.enabled {
                guard case .combo(let existingCombo) = shortcut.keys else { continue }
                if existingCombo == combo {
                    throw ConfigError.conflictingPeekToggle(
                        field: fieldName,
                        keys: combo.canonical,
                        target: "enabled shortcut '\(shortcut.displayName)'"
                    )
                }
                if Self.targetsOverlap(target, shortcut.keys) {
                    throw ConfigError.ambiguousPeekToggle(
                        field: fieldName,
                        keys: combo.canonical,
                        target: "enabled shortcut '\(shortcut.displayName)' ('\(existingCombo.canonical)')"
                    )
                }
            }

        case .sequence(let sequence):
            if sequence.leader == .shift {
                throw ConfigError.malformed(
                    "\(fieldName) '\(sequence.canonical)' is reserved (unsided shift leader conflicts with normal typing; use lshift or rshift)"
                )
            }
            if hasCapsLockRemap && sequence.keyCode == CapsLock.targetKeyCode {
                throw ConfigError.conflictingCapsLockF18(fieldName)
            }
            for shortcut in shortcuts where shortcut.enabled {
                guard case .sequence(let existingSeq) = shortcut.keys else { continue }
                if existingSeq == sequence {
                    throw ConfigError.conflictingPeekToggle(
                        field: fieldName,
                        keys: sequence.canonical,
                        target: "enabled shortcut '\(shortcut.displayName)'"
                    )
                }
                if Self.targetsOverlap(target, shortcut.keys) {
                    throw ConfigError.ambiguousPeekToggle(
                        field: fieldName,
                        keys: sequence.canonical,
                        target: "enabled shortcut '\(shortcut.displayName)' ('\(existingSeq.canonical)')"
                    )
                }
            }

        case .modifier(let modifier):
            for shortcut in shortcuts where shortcut.enabled {
                guard case .modifier(let existingMod) = shortcut.keys,
                      shortcut.doubleTap != nil else { continue }
                if existingMod == modifier {
                    throw ConfigError.conflictingPeekToggle(
                        field: fieldName,
                        keys: modifier.token,
                        target: "enabled shortcut '\(shortcut.displayName)'"
                    )
                }
                if Self.targetsOverlap(target, shortcut.keys) {
                    throw ConfigError.ambiguousPeekToggle(
                        field: fieldName,
                        keys: modifier.token,
                        target: "enabled shortcut '\(shortcut.displayName)' ('\(existingMod.token)')"
                    )
                }
            }
        }
    }

    // MARK: - Strict Codable

    private enum CodingKeys: String, CodingKey {
        case enabled
        case triggers
        case delayMs
        case toggle
        case searchToggle
        case showDisabled
        case dimUnmatched
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: DynamicKey.self)
        let allowedKeys: Set<String> = ["enabled", "triggers", "delayMs", "toggle", "searchToggle", "showDisabled", "dimUnmatched"]
        for key in rawContainer.allKeys where !allowedKeys.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [key],
                    debugDescription: "unknown peek key '\(key.stringValue)'"
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false

        if let rawTriggers = try container.decodeIfPresent([String].self, forKey: .triggers) {
            var parsed: [Modifier] = []
            for raw in rawTriggers {
                guard let mod = Modifier.parse(raw) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .triggers,
                        in: container,
                        debugDescription: "unknown peek trigger modifier '\(raw)'"
                    )
                }
                parsed.append(mod)
            }
            self.triggers = parsed
        } else {
            self.triggers = Self.defaultTriggers
        }

        self.delayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .delayMs)
            ?? Self.defaultDelayMilliseconds

        self.toggle = try Self.decodeOptionalKeyTarget(from: container, forKey: .toggle, fieldName: "peek.toggle")
        self.searchToggle = try Self.decodeOptionalKeyTarget(from: container, forKey: .searchToggle, fieldName: "peek.searchToggle")

        self.showDisabled = try container.decodeIfPresent(Bool.self, forKey: .showDisabled) ?? false
        self.dimUnmatched = try container.decodeIfPresent(Bool.self, forKey: .dimUnmatched) ?? true
    }

    private static func decodeOptionalKeyTarget(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fieldName: String
    ) throws -> KeyTarget? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try KeyTarget.parse(trimmed)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "invalid \(fieldName) '\(raw)': \(error.localizedDescription)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(triggers.map(\.token), forKey: .triggers)
        try container.encode(delayMilliseconds, forKey: .delayMs)
        try container.encodeIfPresent(toggle?.canonical, forKey: .toggle)
        try container.encodeIfPresent(searchToggle?.canonical, forKey: .searchToggle)
        if showDisabled {
            try container.encode(true, forKey: .showDisabled)
        }
        if !dimUnmatched {
            try container.encode(false, forKey: .dimUnmatched)
        }
    }

    /// Deterministic single-line JSON object for `Config.formattedJSON()`.
    public func serializedJSONObject() throws -> String {
        var fields: [String] = []
        fields.append("\"enabled\": \(enabled ? "true" : "false")")
        let triggerTokens = try triggers.map { try Self.jsonString($0.token) }.joined(separator: ", ")
        fields.append("\"triggers\": [\(triggerTokens)]")
        fields.append("\"delayMs\": \(delayMilliseconds)")
        if let toggle {
            fields.append("\"toggle\": \(try Self.jsonString(toggle.canonical))")
        }
        if let searchToggle {
            fields.append("\"searchToggle\": \(try Self.jsonString(searchToggle.canonical))")
        }
        if showDisabled {
            fields.append("\"showDisabled\": true")
        }
        if !dimUnmatched {
            fields.append("\"dimUnmatched\": false")
        }
        return "{ " + fields.joined(separator: ", ") + " }"
    }

    private static func jsonString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
