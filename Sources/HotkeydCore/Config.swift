import Darwin
import Foundation

public struct Config: Codable, Sendable, Equatable {
    public static let maxFileSizeBytes: Int = 1_048_576

    public var version: Int
    public var shortcuts: [Shortcut]
    public var peek: PeekConfig

    public init(version: Int = 1, shortcuts: [Shortcut] = [], peek: PeekConfig = .default) {
        self.version = version
        self.shortcuts = shortcuts
        self.peek = peek
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case shortcuts
        case peek
    }

    fileprivate struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        if let rawContainer = try? decoder.container(keyedBy: DynamicKey.self) {
            let allowedTopKeys: Set<String> = ["version", "shortcuts", "peek"]
            for key in rawContainer.allKeys where !allowedTopKeys.contains(key.stringValue) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "unknown top-level key '\(key.stringValue)'"
                    )
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            let rawShortcuts = try container.decode([Shortcut].self, forKey: .shortcuts)
            self.shortcuts = Self.coalesceLegacyPairs(rawShortcuts)
            self.peek = try container.decodeIfPresent(PeekConfig.self, forKey: .peek) ?? .default
            return
        }
        var arrayContainer = try decoder.unkeyedContainer()
        var decoded: [Shortcut] = []
        while !arrayContainer.isAtEnd {
            decoded.append(try arrayContainer.decode(Shortcut.self))
        }
        self.version = 1
        self.shortcuts = Self.coalesceLegacyPairs(decoded)
        self.peek = .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !peek.isDefault {
            try container.encode(peek, forKey: .peek)
        }
        try container.encode(shortcuts, forKey: .shortcuts)
    }

    /// Coalesces legacy v1 pairs where single-tap (`keys`) and double-tap (`doubleTapKeys`) on the
    /// same key chord were stored as two separate `Shortcut` objects.
    private static func coalesceLegacyPairs(_ items: [Shortcut]) -> [Shortcut] {
        var result: [Shortcut] = []
        for item in items {
            if item.enabled,
               let existingIndex = result.firstIndex(where: {
                   $0.enabled && $0.keys == item.keys
                       && $0.passThrough == item.passThrough
                       && $0.allowAccessibility == item.allowAccessibility
                       && $0.cwd == item.cwd
                       && (($0.tap != nil && $0.doubleTap == nil && item.tap == nil && item.doubleTap != nil)
                           || ($0.tap == nil && $0.doubleTap != nil && item.tap != nil && item.doubleTap == nil))
               }) {
                if result[existingIndex].tap == nil {
                    result[existingIndex].tap = item.tap
                }
                if result[existingIndex].doubleTap == nil {
                    result[existingIndex].doubleTap = item.doubleTap
                }
                if result[existingIndex].maxDoubleTapDelayMilliseconds == nil {
                    result[existingIndex].maxDoubleTapDelayMilliseconds = item.maxDoubleTapDelayMilliseconds
                }
                if result[existingIndex].maxSequenceDelayMilliseconds == nil {
                    result[existingIndex].maxSequenceDelayMilliseconds = item.maxSequenceDelayMilliseconds
                }
                if result[existingIndex].timeoutMilliseconds == nil {
                    result[existingIndex].timeoutMilliseconds = item.timeoutMilliseconds
                }
            } else {
                result.append(item)
            }
        }
        return result
    }

    public static func load(from url: URL) throws -> Config {
        let path = url.path
        let filename = url.lastPathComponent
        let rawParentPath = url.deletingLastPathComponent().path
        let parentPath = StrictModes.normalizeSystemVarPrefix(rawParentPath)
        let currentUID = getuid()

        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !path.contains("\0") else {
            throw ConfigError.insecureConfig("invalid configuration path '\(path)'")
        }

        var parentStat = stat()
        if lstat(parentPath, &parentStat) != 0 {
            let err = errno
            if err == ENOENT {
                throw ConfigError.fileMissing(path)
            }
            throw ConfigError.insecureConfig(
                "parent directory '\(parentPath)' cannot be inspected: \(String(cString: strerror(err)))"
            )
        }

        if !Paths.isEnvironmentOverrideActive {
            do {
                try StrictModes.verifySecurePath(parentPath, expectRegularFile: false)
            } catch {
                throw ConfigError.insecureConfig(error.localizedDescription)
            }
        }

        let dirFD: Int32
        do {
            dirFD = try StrictModes.openVerifiedDirectory(parentPath)
        } catch {
            throw ConfigError.insecureConfig(
                "parent directory '\(parentPath)' failed StrictModes verification: \(error.localizedDescription)"
            )
        }
        defer { close(dirFD) }

        let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            let err = errno
            if err == ENOENT {
                throw ConfigError.fileMissing(path)
            }
            if err == ELOOP {
                throw ConfigError.insecureConfig(
                    "refusing to read symlinked configuration at '\(path)'"
                )
            }
            throw ConfigError.insecureConfig(
                "could not open '\(path)': \(String(cString: strerror(err)))"
            )
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw ConfigError.insecureConfig(
                "fstat failed on '\(path)': \(String(cString: strerror(errno)))"
            )
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError.insecureConfig(
                "configuration at '\(path)' must be a regular file"
            )
        }
        guard st.st_uid == currentUID else {
            throw ConfigError.insecureConfig(
                "configuration at '\(path)' is owned by uid \(st.st_uid); expected uid \(currentUID)"
            )
        }
        guard (st.st_mode & 0o077) == 0 else {
            let perms = String(format: "%04o", st.st_mode & 0o777)
            throw ConfigError.insecureConfig(
                "configuration at '\(path)' has unsafe permissions \(perms); run `chmod 0600 '\(path)'`"
            )
        }
        guard st.st_size >= 0 && st.st_size <= off_t(Self.maxFileSizeBytes) else {
            throw ConfigError.insecureConfig(
                "configuration at '\(path)' exceeds maximum size of \(Self.maxFileSizeBytes) bytes"
            )
        }

        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(fd, baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw ConfigError.insecureConfig(
                    "read failed on '\(path)': \(String(cString: strerror(errno)))"
                )
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
            if data.count > Self.maxFileSizeBytes {
                throw ConfigError.insecureConfig(
                    "configuration at '\(path)' exceeds maximum size of \(Self.maxFileSizeBytes) bytes"
                )
            }
        }

        if data.isEmpty {
            return Config()
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Config.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError.malformed(Self.describe(error, data: data))
        }
    }

    public static func withExclusiveLock<T>(for url: URL = Paths.config, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw ConfigError.insecureConfig("invalid configuration lock target '\(url.path)'")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let normalizedDirPath = StrictModes.normalizeSystemVarPrefix(directory.path)
        if !Paths.isEnvironmentOverrideActive {
            do {
                try StrictModes.verifySecurePath(normalizedDirPath, expectRegularFile: false)
            } catch {
                throw ConfigError.insecureConfig(error.localizedDescription)
            }
        }
        let dirFD: Int32
        do {
            dirFD = try StrictModes.openVerifiedDirectory(normalizedDirPath)
        } catch {
            throw ConfigError.insecureConfig(error.localizedDescription)
        }
        defer { close(dirFD) }

        let lockName = filename.hasPrefix(".") ? "\(filename).lock" : ".\(filename).lock"
        let lockPath = directory.appendingPathComponent(lockName).path
        let lockFD = openat(dirFD, lockName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else {
            throw ConfigError.insecureConfig(
                "could not open lock file '\(lockPath)': \(String(cString: strerror(errno)))"
            )
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0,
              (lockStat.st_mode & S_IFMT) == S_IFREG,
              lockStat.st_uid == getuid() else {
            throw ConfigError.insecureConfig("lock file '\(lockPath)' must be a regular file owned by uid \(getuid())")
        }
        guard fchmod(lockFD, 0o600) == 0 else {
            throw ConfigError.insecureConfig(
                "could not set 0600 permissions on lock file '\(lockPath)': \(String(cString: strerror(errno)))"
            )
        }
        while flock(lockFD, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw ConfigError.insecureConfig(
                "could not lock '\(lockPath)': \(String(cString: strerror(errno)))"
            )
        }
        return try body()
    }

    /// Formats the configuration with one compact JSON object per shortcut line inside `"shortcuts"`.
    public func formattedJSON() throws -> Data {
        var sections: [String] = []
        if !peek.isDefault {
            sections.append("  \"peek\": \(try peek.serializedJSONObject())")
        }
        if shortcuts.isEmpty {
            sections.append("  \"shortcuts\": []")
        } else {
            let lines = try shortcuts.map { "    \(try $0.serializedJSONLine())" }
            sections.append("  \"shortcuts\": [\n" + lines.joined(separator: ",\n") + "\n  ]")
        }
        let text = "{\n" + sections.joined(separator: ",\n") + "\n}\n"
        return Data(text.utf8)
    }

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try formattedJSON()
        do {
            try StrictModes.atomicWrite(data, to: url, mode: 0o600)
        } catch {
            throw ConfigError.insecureConfig(error.localizedDescription)
        }
    }

    public func binding(for modifier: Modifier) -> Shortcut? {
        shortcuts.first { $0.enabled && $0.keys == .modifier(modifier) && $0.doubleTap != nil }
    }

    /// Returns `true` when either an enabled shortcut or an enabled `peek.toggle` / `peek.searchToggle`
    /// target requires Caps Lock -> F18 HID remapping. Default `peek.triggers` alone never hijacks Caps Lock.
    public var requiresCapsLockRemap: Bool {
        let shortcutUsesCaps = shortcuts.contains {
            $0.enabled && $0.keys.usesCapsLock && ($0.tap != nil || $0.doubleTap != nil)
        }
        let peekToggleUsesCaps = peek.enabled && (
            (peek.toggle?.usesCapsLock ?? false) || (peek.searchToggle?.usesCapsLock ?? false)
        )
        return shortcutUsesCaps || peekToggleUsesCaps
    }

    /// Fails loudly rather than letting the daemon pick a surprising winner.
    public func validate() throws {
        var names = Set<String>()
        var tapTriggers: [String: String] = [:]
        var doubleTapTriggers: [String: String] = [:]
        var enabledKeyCombos: [(combo: KeyCombo, name: String)] = []
        var enabledDoubleTapCombos: [(combo: KeyCombo, name: String)] = []
        let hasCapsLockRemap = requiresCapsLockRemap

        let allCanonicalKeys = Set(shortcuts.map { $0.keys.canonical.lowercased() })

        for shortcut in shortcuts {
            let label = shortcut.displayName
            if let explicitName = shortcut.name {
                if explicitName.contains("\0") {
                    throw ConfigError.malformed("shortcut for '\(shortcut.keys.canonical)' has a NUL byte in name")
                }
                let trimmedName = explicitName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedName.isEmpty {
                    throw ConfigError.malformed("shortcut for '\(shortcut.keys.canonical)' has an empty name")
                }
                let lower = trimmedName.lowercased()
                if lower != shortcut.keys.canonical.lowercased() && allCanonicalKeys.contains(lower) {
                    throw ConfigError.malformed(
                        "shortcut name '\(trimmedName)' collides with another shortcut's key binding; choose a distinct name"
                    )
                }
                guard names.insert(lower).inserted else {
                    throw ConfigError.duplicateName(trimmedName)
                }
            }

            let hasTap = shortcut.tap != nil
            let hasDoubleTap = shortcut.doubleTap != nil
            guard hasTap || hasDoubleTap else {
                throw ConfigError.emptyCommand(label)
            }

            if let tapCmd = shortcut.tap {
                if tapCmd.contains("\0") {
                    throw ConfigError.malformed("shortcut '\(label)' tap command contains an embedded NUL byte")
                }
                if tapCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigError.emptyCommand(label)
                }
            }
            if let doubleCmd = shortcut.doubleTap {
                if doubleCmd.contains("\0") {
                    throw ConfigError.malformed("shortcut '\(label)' doubleTap command contains an embedded NUL byte")
                }
                if doubleCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigError.emptyCommand(label)
                }
            }

            if case .modifier = shortcut.keys {
                if hasTap {
                    throw ConfigError.tapOnModifier(label)
                }
                if shortcut.passThrough {
                    throw ConfigError.passThroughOnGesture(label)
                }
            }
            if case .sequence = shortcut.keys, hasDoubleTap {
                throw ConfigError.doubleTapOnSequence(label)
            }

            if let cwd = shortcut.cwd {
                guard Paths.resolveWorkingDirectory(cwd) != nil else {
                    throw ConfigError.invalidWorkingDirectory(label, cwd)
                }
            }
            if let timeoutMs = shortcut.timeoutMilliseconds, !(1...600_000).contains(timeoutMs) {
                throw ConfigError.invalidTimeout(label, timeoutMs)
            }
            if let doubleTapDelay = shortcut.maxDoubleTapDelayMilliseconds {
                guard hasDoubleTap else {
                    throw ConfigError.doubleTapDelayWithoutDoubleTap(label)
                }
                guard (100...600).contains(doubleTapDelay) else {
                    throw ConfigError.invalidDoubleTapDelay(label, doubleTapDelay)
                }
            }
            if let sequenceDelay = shortcut.maxSequenceDelayMilliseconds {
                guard case .sequence = shortcut.keys else {
                    throw ConfigError.sequenceDelayOnNonSequence(label)
                }
                guard (100...1500).contains(sequenceDelay) else {
                    throw ConfigError.invalidSequenceDelay(label, sequenceDelay)
                }
            }

            guard shortcut.enabled else { continue }

            switch shortcut.keys {
            case .modifier(let modifier):
                let triggerID = "doubleTap:\(modifier.token)"
                if let existing = doubleTapTriggers[triggerID] {
                    throw ConfigError.duplicateTrigger(triggerID, existing, label)
                }
                doubleTapTriggers[triggerID] = label

            case .combo(let combo):
                if hasCapsLockRemap && combo.keyCode == CapsLock.targetKeyCode {
                    throw ConfigError.conflictingCapsLockF18(label)
                }
                if let reason = combo.reservedReason {
                    throw ConfigError.malformed("'\(combo.canonical)' is reserved (\(reason))")
                }
                if hasTap {
                    let triggerID = combo.canonical
                    if let existing = tapTriggers[triggerID] {
                        throw ConfigError.duplicateTrigger(triggerID, existing, label)
                    }
                    tapTriggers[triggerID] = label
                    for existing in enabledKeyCombos where existing.combo.overlapsAmbiguously(with: combo) {
                        throw ConfigError.ambiguousTrigger(existing.name, label)
                    }
                    enabledKeyCombos.append((combo, label))
                }
                if hasDoubleTap {
                    let triggerID = "doubleTap:\(combo.canonical)"
                    if let existing = doubleTapTriggers[triggerID] {
                        throw ConfigError.duplicateTrigger(triggerID, existing, label)
                    }
                    doubleTapTriggers[triggerID] = label
                    for existing in enabledDoubleTapCombos where existing.combo.overlapsAmbiguously(with: combo) {
                        throw ConfigError.ambiguousTrigger(existing.name, label)
                    }
                    enabledDoubleTapCombos.append((combo, label))
                }

            case .sequence(let seq):
                if hasCapsLockRemap && seq.keyCode == CapsLock.targetKeyCode {
                    throw ConfigError.conflictingCapsLockF18(label)
                }
                if seq.leader == .shift {
                    throw ConfigError.malformed("'\(seq.canonical)' is reserved (unsided shift leader conflicts with normal typing; use lshift or rshift)")
                }
                if hasTap {
                    let triggerID = seq.canonical
                    if let existing = tapTriggers[triggerID] {
                        throw ConfigError.duplicateTrigger(triggerID, existing, label)
                    }
                    tapTriggers[triggerID] = label
                }
            }
        }

        try peek.validate(against: shortcuts, hasCapsLockRemap: hasCapsLockRemap)
    }

    /// Detects enabled single-modifier combos (`mod+key`) that share the same modifier and key as
    /// an enabled sequence (`mod > key`), where fast release rollover can flip between actions.
    public func rolloverWarnings() -> [String] {
        var warnings: [String] = []
        let enabled = shortcuts.filter(\.enabled)
        let singleModCombos: [(shortcut: Shortcut, modifier: Modifier, keyCode: UInt16)] = enabled.compactMap { shortcut in
            guard case .combo(let combo) = shortcut.keys,
                  combo.modifiers.count == 1,
                  let mod = combo.modifiers.first else {
                return nil
            }
            return (shortcut, mod, combo.keyCode)
        }
        for shortcut in enabled {
            guard case .sequence(let seq) = shortcut.keys else { continue }
            for item in singleModCombos where item.keyCode == seq.keyCode {
                let sameFamily = item.modifier.family == seq.leader.family
                let compatibleSide = item.modifier.side == nil
                    || seq.leader.side == nil
                    || item.modifier.side == seq.leader.side
                if sameFamily && compatibleSide {
                    warnings.append(
                        "rollover overlap: '\(item.shortcut.keys.canonical)' (\(item.shortcut.displayName)) and '\(seq.canonical)' (\(shortcut.displayName)) share the same modifier and key"
                    )
                }
            }
        }
        return warnings
    }

    private static func formatCodingPath(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "" }
        var out = ""
        for key in codingPath {
            if let index = key.intValue {
                out += "[\(index)]"
            } else {
                if !out.isEmpty { out += "." }
                out += key.stringValue
            }
        }
        return out
    }

    private static func describe(_ error: DecodingError, data: Data? = nil) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            let path = formatCodingPath(context.codingPath)
            let location = path.isEmpty ? "" : " at \(path)"
            return "missing key '\(key.stringValue)'\(location)"
        case .valueNotFound(_, let context):
            let path = formatCodingPath(context.codingPath)
            let location = path.isEmpty ? "configuration" : path
            return "null or missing value at \(location)"
        case .typeMismatch(let expected, let context):
            let path = formatCodingPath(context.codingPath)
            let location = path.isEmpty ? "configuration" : path
            return "wrong type at \(location) (expected \(expected)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            let path = formatCodingPath(context.codingPath)
            let prefix = path.isEmpty ? "" : "at \(path): "
            var detail = context.debugDescription
            if let nsError = context.underlyingError as NSError?,
               let underlying = nsError.userInfo[NSDebugDescriptionErrorKey] as? String,
               !underlying.isEmpty,
               !detail.contains(underlying) {
                detail += " (\(underlying))"
            }
            if let data,
               let text = String(data: data, encoding: .utf8) {
                if text.contains(",]") || text.contains(",\n]") || text.contains(", }") || text.contains(",\n  ]") {
                    detail += "; hint: JSON does not allow trailing commas"
                } else if text.contains("\n//") || text.hasPrefix("//") {
                    detail += "; hint: JSON does not allow // comments"
                }
            }
            return "corrupted data \(prefix)\(detail)"
        default:
            return "could not decode configuration"
        }
    }
}

public enum KeyTarget: Sendable, Equatable, Hashable {
    case modifier(Modifier)
    case combo(KeyCombo)
    case sequence(KeySequence)

    public var canonical: String {
        switch self {
        case .modifier(let modifier): return modifier.token
        case .combo(let combo): return combo.canonical
        case .sequence(let sequence): return sequence.canonical
        }
    }

    public var modifier: Modifier? {
        guard case .modifier(let mod) = self else { return nil }
        return mod
    }

    public var combo: KeyCombo? {
        guard case .combo(let combo) = self else { return nil }
        return combo
    }

    public var sequence: KeySequence? {
        guard case .sequence(let sequence) = self else { return nil }
        return sequence
    }

    public var usesCapsLock: Bool {
        switch self {
        case .modifier(let mod): return mod == .capsLock
        case .combo(let combo): return combo.modifiers.contains(.capsLock)
        case .sequence(let seq): return seq.leader == .capsLock
        }
    }

    public static func parse(_ raw: String) throws -> KeyTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyComboError.empty }
        if trimmed.contains(">") {
            return .sequence(try KeySequence.parse(trimmed))
        }
        if !trimmed.contains("+"),
           let colonIndex = trimmed.firstIndex(of: ":"),
           Modifier.parse(String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)) != nil {
            return .sequence(try KeySequence.parse(trimmed))
        }
        if !trimmed.contains("+"), let modifier = Modifier.parse(trimmed) {
            return .modifier(modifier)
        }
        return .combo(try KeyCombo.parse(trimmed))
    }
}

public struct Shortcut: Codable, Sendable, Equatable {
    public var keys: KeyTarget
    public var tap: String?
    public var doubleTap: String?
    public var name: String?
    public var enabled: Bool
    /// Only meaningful for key combos and sequences: let the focused app see the keystroke as well.
    public var passThrough: Bool
    /// When false (the default), spawned shells disclaim hotkeyd's Accessibility TCC attribution.
    public var allowAccessibility: Bool
    public var maxDoubleTapDelayMilliseconds: Int?
    public var maxSequenceDelayMilliseconds: Int?
    public var timeoutMilliseconds: Int?
    public var cwd: String?

    /// Backwards-compatible alias for `maxDoubleTapDelayMilliseconds`.
    public var windowMilliseconds: Int? {
        get { maxDoubleTapDelayMilliseconds }
        set { maxDoubleTapDelayMilliseconds = newValue }
    }

    public init(
        keys: KeyTarget,
        tap: String? = nil,
        doubleTap: String? = nil,
        name: String? = nil,
        enabled: Bool = true,
        passThrough: Bool = false,
        allowAccessibility: Bool = false,
        maxDoubleTapDelayMilliseconds: Int? = nil,
        maxSequenceDelayMilliseconds: Int? = nil,
        windowMilliseconds: Int? = nil,
        timeoutMilliseconds: Int? = nil,
        cwd: String? = nil
    ) {
        self.keys = keys
        self.tap = tap
        self.doubleTap = doubleTap
        self.name = name
        self.enabled = enabled
        self.passThrough = passThrough
        self.allowAccessibility = allowAccessibility
        self.maxDoubleTapDelayMilliseconds = maxDoubleTapDelayMilliseconds ?? windowMilliseconds
        self.maxSequenceDelayMilliseconds = maxSequenceDelayMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
        self.cwd = cwd
    }

    /// Convenience initializer for legacy call sites using `Trigger` and `Action`.
    public init(
        id: String = "",
        name: String? = nil,
        enabled: Bool = true,
        trigger: Trigger,
        action: Action,
        passThrough: Bool = false,
        allowAccessibility: Bool = false
    ) {
        self.name = name
        self.enabled = enabled
        self.passThrough = passThrough
        self.allowAccessibility = allowAccessibility
        self.maxDoubleTapDelayMilliseconds = trigger.windowMilliseconds
        self.maxSequenceDelayMilliseconds = trigger.sequenceDelayMilliseconds
        self.timeoutMilliseconds = action.timeoutMilliseconds
        self.cwd = action.cwd

        let commandString = action.shellCommandString
        switch trigger {
        case .doubleTap(let modifier, _):
            self.keys = .modifier(modifier)
            self.tap = nil
            self.doubleTap = commandString
        case .keys(let combo):
            self.keys = .combo(combo)
            self.tap = commandString
            self.doubleTap = nil
        case .doubleTapKeys(let combo, _):
            self.keys = .combo(combo)
            self.tap = nil
            self.doubleTap = commandString
        case .sequence(let sequence, _):
            self.keys = .sequence(sequence)
            self.tap = commandString
            self.doubleTap = nil
        }
    }

    public static func newID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    public var displayName: String {
        name ?? keys.canonical
    }

    public var maxDoubleTapDelaySeconds: Double? {
        maxDoubleTapDelayMilliseconds.map { Double($0) / 1000 }
    }

    public var maxSequenceDelaySeconds: Double? {
        maxSequenceDelayMilliseconds.map { Double($0) / 1000 }
    }

    public var windowSeconds: Double? {
        maxDoubleTapDelaySeconds
    }

    public var activeCommand: String {
        tap ?? doubleTap ?? ""
    }

    public var activeAction: Action {
        .shell(command: activeCommand, cwd: cwd, timeoutMilliseconds: timeoutMilliseconds)
    }

    public var usesSelectedText: Bool {
        (tap.map(SelectionReader.commandUsesSelectedText) ?? false)
            || (doubleTap.map(SelectionReader.commandUsesSelectedText) ?? false)
    }

    public func executionMode(for command: String?) -> String {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "shell"
        }
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !allowAccessibility,
           !SelectionReader.commandUsesSelectedText(command),
           trimmedCwd.isEmpty,
           let fast = Action.migratedFromShellCommand(command) {
            switch fast {
            case .app: return "native-app"
            case .url: return "native-url"
            case .openPath: return "native-path"
            case .shell: return "shell"
            }
        }
        return "shell"
    }

    public var primaryExecutionMode: String {
        executionMode(for: tap ?? doubleTap)
    }

    public var trigger: Trigger {
        switch keys {
        case .modifier(let modifier):
            return .doubleTap(modifier: modifier, windowMilliseconds: maxDoubleTapDelayMilliseconds)
        case .combo(let combo):
            if doubleTap != nil && tap == nil {
                return .doubleTapKeys(combo, windowMilliseconds: maxDoubleTapDelayMilliseconds)
            }
            return .keys(combo)
        case .sequence(let sequence):
            return .sequence(sequence, maxSequenceDelayMilliseconds: maxSequenceDelayMilliseconds)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keys
        case tap
        case doubleTap
        case name
        case maxDoubleTapDelayMs
        case maxSequenceDelayMs
        case windowMs
        case timeoutMs
        case cwd
        case passThrough
        case allowAccessibility
        case enabled
        // Legacy v1 keys
        case id
        case trigger
        case action
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: Config.DynamicKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Legacy v1 format support (`trigger` + `action`)
        if container.contains(.trigger) && container.contains(.action) {
            let allowedLegacyKeys: Set<String> = [
                "id", "name", "enabled", "trigger", "action", "passThrough", "allowAccessibility"
            ]
            for key in rawContainer.allKeys where !allowedLegacyKeys.contains(key.stringValue) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "unknown shortcut key '\(key.stringValue)'"
                    )
                )
            }
            let legacyTrigger = try container.decode(Trigger.self, forKey: .trigger)
            let legacyAction = try container.decode(Action.self, forKey: .action)
            let rawName = try container.decodeIfPresent(String.self, forKey: .name)
            let decodedEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            let decodedPassThrough = try container.decodeIfPresent(Bool.self, forKey: .passThrough) ?? false
            let decodedAllowAX = try container.decodeIfPresent(Bool.self, forKey: .allowAccessibility) ?? false
            self.init(
                name: Self.stripAutoGeneratedLegacyName(rawName, trigger: legacyTrigger),
                enabled: decodedEnabled,
                trigger: legacyTrigger,
                action: legacyAction,
                passThrough: decodedPassThrough,
                allowAccessibility: decodedAllowAX
            )
            return
        }

        let allowedUnifiedKeys: Set<String> = [
            "keys", "tap", "doubleTap", "name",
            "maxDoubleTapDelayMs", "maxSequenceDelayMs", "windowMs",
            "timeoutMs", "cwd", "passThrough", "allowAccessibility", "enabled"
        ]
        for key in rawContainer.allKeys where !allowedUnifiedKeys.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [key],
                    debugDescription: "unknown shortcut key '\(key.stringValue)'"
                )
            )
        }

        let rawKeys = try container.decode(String.self, forKey: .keys)
        let parsedKeys: KeyTarget
        do {
            parsedKeys = try KeyTarget.parse(rawKeys)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .keys,
                in: container,
                debugDescription: error.localizedDescription
            )
        }

        if container.contains(.maxDoubleTapDelayMs) && container.contains(.windowMs) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "use only 'maxDoubleTapDelayMs', not both 'maxDoubleTapDelayMs' and legacy 'windowMs'"
                )
            )
        }

        let decodedTap = try Self.decodeCommandOrAction(from: container, forKey: .tap)
        let decodedDoubleTap = try Self.decodeCommandOrAction(from: container, forKey: .doubleTap)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedDoubleTapDelay = try container.decodeIfPresent(Int.self, forKey: .maxDoubleTapDelayMs)
            ?? container.decodeIfPresent(Int.self, forKey: .windowMs)
        let decodedSequenceDelay = try container.decodeIfPresent(Int.self, forKey: .maxSequenceDelayMs)
        let decodedTimeout = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
        let decodedCwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        let decodedPassThrough = try container.decodeIfPresent(Bool.self, forKey: .passThrough) ?? false
        let decodedAllowAX = try container.decodeIfPresent(Bool.self, forKey: .allowAccessibility) ?? false
        let decodedEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        self.init(
            keys: parsedKeys,
            tap: decodedTap,
            doubleTap: decodedDoubleTap,
            name: decodedName,
            enabled: decodedEnabled,
            passThrough: decodedPassThrough,
            allowAccessibility: decodedAllowAX,
            maxDoubleTapDelayMilliseconds: decodedDoubleTapDelay,
            maxSequenceDelayMilliseconds: decodedSequenceDelay,
            timeoutMilliseconds: decodedTimeout,
            cwd: decodedCwd
        )
    }

    private static func decodeCommandOrAction(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            return str
        }
        let action = try container.decode(Action.self, forKey: key)
        return action.shellCommandString
    }

    private static func stripAutoGeneratedLegacyName(_ rawName: String?, trigger: Trigger) -> String? {
        guard let name = rawName else { return nil }
        let lower = name.lowercased()
        switch trigger {
        case .doubleTap(let modifier, _):
            if lower == "doubletap-\(modifier.token.lowercased())"
                || (modifier == .capsLock && lower == "capslock") {
                return nil
            }
        case .keys(let combo):
            if lower == "keys-\(combo.canonical.lowercased())" {
                return nil
            }
        case .doubleTapKeys(let combo, _):
            if lower == "doubletap-\(combo.canonical.lowercased())" {
                return nil
            }
        case .sequence(let sequence, _):
            if lower == "sequence-\(sequence.canonical.lowercased())"
                || lower == "keys-\(sequence.canonical.lowercased())" {
                return nil
            }
        }
        return name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys.canonical, forKey: .keys)
        try container.encodeIfPresent(tap, forKey: .tap)
        try container.encodeIfPresent(doubleTap, forKey: .doubleTap)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(maxDoubleTapDelayMilliseconds, forKey: .maxDoubleTapDelayMs)
        try container.encodeIfPresent(maxSequenceDelayMilliseconds, forKey: .maxSequenceDelayMs)
        try container.encodeIfPresent(timeoutMilliseconds, forKey: .timeoutMs)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        if passThrough {
            try container.encode(true, forKey: .passThrough)
        }
        if allowAccessibility {
            try container.encode(true, forKey: .allowAccessibility)
        }
        if !enabled {
            try container.encode(false, forKey: .enabled)
        }
    }

    /// Produces a single-line JSON object with deterministic field ordering (`keys`, `tap`, `doubleTap`, ...).
    public func serializedJSONLine() throws -> String {
        var fields: [String] = []
        fields.append("\"keys\": \(try Self.jsonString(keys.canonical))")
        if let tap {
            fields.append("\"tap\": \(try Self.jsonString(tap))")
        }
        if let doubleTap {
            fields.append("\"doubleTap\": \(try Self.jsonString(doubleTap))")
        }
        if let name {
            fields.append("\"name\": \(try Self.jsonString(name))")
        }
        if let maxDoubleTapDelayMilliseconds {
            fields.append("\"maxDoubleTapDelayMs\": \(maxDoubleTapDelayMilliseconds)")
        }
        if let maxSequenceDelayMilliseconds {
            fields.append("\"maxSequenceDelayMs\": \(maxSequenceDelayMilliseconds)")
        }
        if let timeoutMilliseconds {
            fields.append("\"timeoutMs\": \(timeoutMilliseconds)")
        }
        if let cwd {
            fields.append("\"cwd\": \(try Self.jsonString(cwd))")
        }
        if passThrough {
            fields.append("\"passThrough\": true")
        }
        if allowAccessibility {
            fields.append("\"allowAccessibility\": true")
        }
        if !enabled {
            fields.append("\"enabled\": false")
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

public enum Trigger: Sendable, Equatable {
    case doubleTap(modifier: Modifier, windowMilliseconds: Int?)
    case keys(KeyCombo)
    /// Double-tap a key while holding its modifiers, e.g. hold fn and tap esc twice.
    case doubleTapKeys(KeyCombo, windowMilliseconds: Int?)
    /// Two-step sequence: tap a modifier leader, then press a bare non-modifier key, e.g. `fn > q`.
    case sequence(KeySequence, maxSequenceDelayMilliseconds: Int?)

    public var modifier: Modifier? {
        guard case .doubleTap(let modifier, _) = self else { return nil }
        return modifier
    }

    public var windowMilliseconds: Int? {
        switch self {
        case .doubleTap(_, let window), .doubleTapKeys(_, let window):
            return window
        case .keys, .sequence:
            return nil
        }
    }

    public var sequenceDelayMilliseconds: Int? {
        guard case .sequence(_, let delay) = self else { return nil }
        return delay
    }

    public var windowSeconds: Double? {
        windowMilliseconds.map { Double($0) / 1000 }
    }

    /// Canonical, round-trippable display form.
    public var display: String {
        switch self {
        case .doubleTap(let modifier, _): return "doubleTap:\(modifier.token)"
        case .keys(let combo): return combo.canonical
        case .doubleTapKeys(let combo, _): return "doubleTapKeys:\(combo.canonical)"
        case .sequence(let sequence, _): return sequence.canonical
        }
    }

    public var identity: String { display }
}

extension Trigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case modifier
        case maxDoubleTapDelayMs
        case maxSequenceDelayMs
        case windowMs
    }

    private enum Kind: String, Codable {
        case doubleTap
        case keys
        case doubleTapKeys
        case sequence
    }

    private enum KeyKeys: String, CodingKey {
        case keys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .doubleTap:
            let raw = try container.decode(String.self, forKey: .modifier)
            guard let modifier = Modifier.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modifier,
                    in: container,
                    debugDescription: "unknown modifier '\(raw)'; expected command, option, control, shift or fn"
                )
            }
            let delay = try container.decodeIfPresent(Int.self, forKey: .maxDoubleTapDelayMs)
                ?? container.decodeIfPresent(Int.self, forKey: .windowMs)
            self = .doubleTap(modifier: modifier, windowMilliseconds: delay)
        case .keys, .doubleTapKeys:
            let keysContainer = try decoder.container(keyedBy: KeyKeys.self)
            let raw = try keysContainer.decode(String.self, forKey: .keys)
            let combo: KeyCombo
            do {
                combo = try KeyCombo.parse(raw)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .keys,
                    in: keysContainer,
                    debugDescription: error.localizedDescription
                )
            }
            if kind == .keys {
                self = .keys(combo)
            } else {
                let delay = try container.decodeIfPresent(Int.self, forKey: .maxDoubleTapDelayMs)
                    ?? container.decodeIfPresent(Int.self, forKey: .windowMs)
                self = .doubleTapKeys(combo, windowMilliseconds: delay)
            }
        case .sequence:
            let keysContainer = try decoder.container(keyedBy: KeyKeys.self)
            let raw = try keysContainer.decode(String.self, forKey: .keys)
            let seq: KeySequence
            do {
                seq = try KeySequence.parse(raw)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .keys,
                    in: keysContainer,
                    debugDescription: error.localizedDescription
                )
            }
            let delay = try container.decodeIfPresent(Int.self, forKey: .maxSequenceDelayMs)
            self = .sequence(seq, maxSequenceDelayMilliseconds: delay)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .doubleTap(let modifier, let window):
            try container.encode(Kind.doubleTap, forKey: .type)
            try container.encode(modifier.token, forKey: .modifier)
            try container.encodeIfPresent(window, forKey: .windowMs)
        case .keys(let combo):
            try container.encode(Kind.keys, forKey: .type)
            var nested = encoder.container(keyedBy: KeyKeys.self)
            try nested.encode(combo.canonical, forKey: .keys)
        case .doubleTapKeys(let combo, let window):
            try container.encode(Kind.doubleTapKeys, forKey: .type)
            var nested = encoder.container(keyedBy: KeyKeys.self)
            try nested.encode(combo.canonical, forKey: .keys)
            try container.encodeIfPresent(window, forKey: .windowMs)
        case .sequence(let sequence, let delay):
            try container.encode(Kind.sequence, forKey: .type)
            var nested = encoder.container(keyedBy: KeyKeys.self)
            try nested.encode(sequence.canonical, forKey: .keys)
            try container.encodeIfPresent(delay, forKey: .maxSequenceDelayMs)
        }
    }
}

public enum Action: Sendable, Equatable {
    case shell(command: String, cwd: String?, timeoutMilliseconds: Int?)
    case app(target: String, arguments: [String] = [])
    case url(String)
    case openPath(String)

    public var cwd: String? {
        if case .shell(_, let cwd, _) = self { return cwd }
        return nil
    }

    public var timeoutMilliseconds: Int? {
        if case .shell(_, _, let timeout) = self { return timeout }
        return nil
    }

    private static let unquotedForbiddenShellChars: Set<Character> = [
        ";", "|", "&", "$", "`", ">", "<", "(", ")", "\n", "\r", "*", "?", "[", "]", "{", "}", "!", "#"
    ]

    /// Strict POSIX single-quoting so arbitrary strings cannot trigger shell expansion or splitting.
    public static func shellSingleQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Formats a single shell argument safely without breaking simple human-readable app names
    /// (such as `"Google Chrome"`).
    public static func shellArgument(_ raw: String) -> String {
        guard !raw.isEmpty else { return "''" }
        let needsStrongQuote = raw.contains { ch in
            unquotedForbiddenShellChars.contains(ch)
                || ch == "'"
                || ch == "\""
                || ch == "\\"
                || ch == "\0"
                || ch == "\t"
        }
        if needsStrongQuote {
            return shellSingleQuote(raw)
        }
        if raw.contains(where: \.isWhitespace) {
            return "\"\(raw)\""
        }
        return raw
    }

    public var shellCommandString: String {
        switch self {
        case .shell(let command, _, _):
            return command
        case .app(let target, let arguments):
            let quotedTarget = Self.shellArgument(target)
            if arguments.isEmpty {
                return "open -a \(quotedTarget)"
            }
            let argsText = arguments.map(Self.shellArgument).joined(separator: " ")
            return "open -a \(quotedTarget) --args \(argsText)"
        case .url(let rawURL):
            return "open \(Self.shellArgument(rawURL))"
        case .openPath(let path):
            return "open \(Self.shellArgument(path))"
        }
    }

    public var summary: String {
        switch self {
        case .shell(let command, _, _):
            let single = command.replacingOccurrences(of: "\n", with: " ; ")
            return single.count > 72 ? String(single.prefix(69)) + "..." : single
        case .app(let target, let arguments):
            let suffix = arguments.isEmpty ? "" : " " + arguments.joined(separator: " ")
            let full = "app:\(target)\(suffix)"
            return full.count > 72 ? String(full.prefix(69)) + "..." : full
        case .url(let rawURL):
            let full = "url:\(rawURL)"
            return full.count > 72 ? String(full.prefix(69)) + "..." : full
        case .openPath(let path):
            let full = "open:\(path)"
            return full.count > 72 ? String(full.prefix(69)) + "..." : full
        }
    }

    /// Validates that `raw` is a well-formed `http` or `https` URL with a non-empty host.
    public static func validatedWebURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host,
            !host.isEmpty,
            let url = components.url
        else {
            return nil
        }
        return url
    }

    public static func isValidWebURL(_ raw: String) -> Bool {
        validatedWebURL(raw) != nil
    }

    /// Recognizes simple metacharacter-free `open -a <App> [--args ...]`, `open <https://...>`,
    /// or `open <~ | ~/... | /abs/dir>` commands so `ShellRunner` can execute them natively via
    /// `NSWorkspace` without spawning `/bin/zsh`.
    public static func migratedFromShellCommand(_ command: String) -> Action? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            return nil
        }
        guard let tokens = tokenizeSimpleCommand(trimmed), !tokens.isEmpty else {
            return nil
        }
        guard tokens[0] == "open" || tokens[0] == "/usr/bin/open" else {
            return nil
        }
        if tokens.count == 2 {
            let candidate = tokens[1]
            if isValidWebURL(candidate) {
                return .url(candidate)
            }
            if candidate == "~" || candidate.hasPrefix("~/") || candidate.hasPrefix("/") {
                return .openPath(candidate)
            }
            return nil
        }
        if tokens.count >= 3 && (tokens[1] == "-a" || tokens[1] == "-b") {
            let target = tokens[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, !target.hasPrefix("-") else { return nil }
            if tokens.count == 3 {
                return .app(target: target, arguments: [])
            }
            if tokens[3] == "--args" {
                return .app(target: target, arguments: Array(tokens.dropFirst(4)))
            }
        }
        return nil
    }

    private static func tokenizeSimpleCommand(_ input: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var iterator = input.makeIterator()

        while let ch = iterator.next() {
            if let activeQuote = quote {
                if ch == activeQuote {
                    quote = nil
                } else if activeQuote == "\"" {
                    if ch == "$" || ch == "`" {
                        return nil
                    }
                    if ch == "\\" {
                        guard let escaped = iterator.next() else { return nil }
                        guard escaped == "\"" || escaped == "\\" else { return nil }
                        current.append(escaped)
                    } else {
                        current.append(ch)
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if unquotedForbiddenShellChars.contains(ch) {
                    return nil
                }
                if ch == "'" || ch == "\"" {
                    quote = ch
                    inToken = true
                } else if ch.isWhitespace {
                    if inToken {
                        tokens.append(current)
                        current = ""
                        inToken = false
                    }
                } else if ch == "\\" {
                    guard let escaped = iterator.next() else { return nil }
                    if escaped == "\n" || escaped == "\r" || escaped == "\0" {
                        return nil
                    }
                    current.append(escaped)
                    inToken = true
                } else {
                    current.append(ch)
                    inToken = true
                }
            }
        }

        if quote != nil {
            return nil
        }
        if inToken {
            tokens.append(current)
        }
        return tokens
    }
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case cwd
        case timeoutMs
        case target
        case arguments
        case url
        case path
    }

    private enum Kind: String, Codable {
        case shell
        case app
        case url
        case open
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .shell:
            self = .shell(
                command: try container.decode(String.self, forKey: .command),
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                timeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
            )
        case .app:
            let target = try container.decode(String.self, forKey: .target)
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("\0") {
                throw DecodingError.dataCorruptedError(
                    forKey: .target,
                    in: container,
                    debugDescription: "app target must not be empty"
                )
            }
            let arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            if arguments.contains(where: { $0.contains("\0") }) {
                throw DecodingError.dataCorruptedError(
                    forKey: .arguments,
                    in: container,
                    debugDescription: "app arguments must not contain NUL bytes"
                )
            }
            self = .app(target: target, arguments: arguments)
        case .url:
            let rawURL = try container.decode(String.self, forKey: .url)
            guard Self.validatedWebURL(rawURL) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: container,
                    debugDescription: "unsafe or invalid URL '\(rawURL)'; expected http:// or https:// with a host"
                )
            }
            self = .url(rawURL)
        case .open:
            let path = try container.decode(String.self, forKey: .path)
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty
                || trimmed.contains("\0")
                || trimmed.contains("\n")
                || trimmed.contains("\r")
                || trimmed.hasPrefix("-") {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "open path must be a non-empty path without NUL/newline bytes or leading '-'"
                )
            }
            self = .openPath(path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shell(let command, let cwd, let timeout):
            try container.encode(Kind.shell, forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(cwd, forKey: .cwd)
            try container.encodeIfPresent(timeout, forKey: .timeoutMs)
        case .app(let target, let arguments):
            try container.encode(Kind.app, forKey: .type)
            try container.encode(target, forKey: .target)
            if !arguments.isEmpty {
                try container.encode(arguments, forKey: .arguments)
            }
        case .url(let rawURL):
            try container.encode(Kind.url, forKey: .type)
            try container.encode(rawURL, forKey: .url)
        case .openPath(let path):
            try container.encode(Kind.open, forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

public enum ConfigError: LocalizedError, Equatable {
    case fileMissing(String)
    case insecureConfig(String)
    case malformed(String)
    case duplicateName(String)
    case duplicateTrigger(String, String, String)
    case ambiguousTrigger(String, String)
    case conflictingCapsLockF18(String)
    case emptyCommand(String)
    case tapOnModifier(String)
    case doubleTapOnSequence(String)
    case doubleTapDelayWithoutDoubleTap(String)
    case sequenceDelayOnNonSequence(String)
    case invalidWorkingDirectory(String, String)
    case invalidDoubleTapDelay(String, Int)
    case invalidSequenceDelay(String, Int)
    case invalidTimeout(String, Int)
    case passThroughOnGesture(String)
    case allowAccessibilityOnNonShell(String)
    case invalidAppTarget(String, String)
    case invalidURL(String, String)
    case invalidPeekDelay(Int)
    case duplicatePeekTrigger(String)
    case conflictingPeekToggle(field: String, keys: String, target: String)
    case ambiguousPeekToggle(field: String, keys: String, target: String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            return "no configuration at \(path); create one with `hotkeyd add cmd 'open -a Terminal'`"
        case .insecureConfig(let detail):
            return "unsafe configuration file: \(detail)"
        case .malformed(let detail):
            return "configuration is invalid: \(detail)"
        case .duplicateName(let name):
            return "a shortcut named '\(name)' already exists"
        case .duplicateTrigger(let trigger, let existing, let candidate):
            return "\(trigger) is already bound to '\(existing)'; cannot also bind '\(candidate)'"
        case .ambiguousTrigger(let first, let second):
            return "shortcuts '\(first)' and '\(second)' have overlapping partial side-specific modifiers with equal precedence"
        case .conflictingCapsLockF18(let name):
            return "shortcut '\(name)' binds f18 while a capsLock binding is enabled (Caps Lock remaps to F18)"
        case .emptyCommand(let name):
            return "shortcut '\(name)' must define a non-empty tap or doubleTap command"
        case .tapOnModifier(let name):
            return "shortcut '\(name)' sets tap on a bare modifier; modifiers only support doubleTap"
        case .doubleTapOnSequence(let name):
            return "shortcut '\(name)' sets doubleTap on a sequence; '<modifier> > <key>' sequences only support tap"
        case .doubleTapDelayWithoutDoubleTap(let name):
            return "shortcut '\(name)' sets maxDoubleTapDelayMs without a doubleTap command"
        case .sequenceDelayOnNonSequence(let name):
            return "shortcut '\(name)' sets maxSequenceDelayMs on a non-sequence binding; maxSequenceDelayMs only applies to '<modifier> > <key>' sequences"
        case .invalidWorkingDirectory(let name, let cwd):
            return "shortcut '\(name)' has invalid cwd '\(cwd)'; expected an absolute path or '~'"
        case .invalidDoubleTapDelay(let name, let delay):
            return "shortcut '\(name)' has maxDoubleTapDelayMs \(delay); expected 100...600"
        case .invalidSequenceDelay(let name, let delay):
            return "shortcut '\(name)' has maxSequenceDelayMs \(delay); expected 100...1500"
        case .invalidTimeout(let name, let timeout):
            return "shortcut '\(name)' has timeoutMs \(timeout); expected 1...600000"
        case .passThroughOnGesture(let name):
            return "shortcut '\(name)' sets passThrough on a modifier gesture; gestures consume nothing, so the flag is meaningless"
        case .allowAccessibilityOnNonShell(let name):
            return "shortcut '\(name)' sets allowAccessibility on a non-shell action; only shell actions spawn processes"
        case .invalidAppTarget(let name, let target):
            return "shortcut '\(name)' has invalid app target '\(target)'"
        case .invalidURL(let name, let rawURL):
            return "shortcut '\(name)' has invalid or disallowed URL '\(rawURL)'; only http:// and https:// URLs are allowed"
        case .invalidPeekDelay(let delay):
            return "peek.delayMs \(delay) is out of range; expected \(PeekConfig.minDelayMilliseconds)...\(PeekConfig.maxDelayMilliseconds)"
        case .duplicatePeekTrigger(let token):
            return "peek.triggers contains duplicate or overlapping modifier '\(token)'"
        case .conflictingPeekToggle(let field, let toggleKeys, let target):
            return "\(field) '\(toggleKeys)' collides with \(target)"
        case .ambiguousPeekToggle(let field, let toggleKeys, let target):
            return "\(field) '\(toggleKeys)' overlaps ambiguously with \(target)"
        }
    }
}
