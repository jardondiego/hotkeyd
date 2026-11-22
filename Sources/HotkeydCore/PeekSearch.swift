import Foundation

/// Single searchable shortcut slot (expanded per `tap` and `doubleTap`) sent to the TCC-disclaimed
/// Spotlight Search HUD or rendered offline via `hotkeyd peek --search --terminal`.
public struct PeekSearchItem: Codable, Sendable, Equatable {
    public let id: String
    public let slot: String
    public let canonicalKeys: String
    public let keyPills: [String]
    public let keyDisplay: String
    public let keySearchAliases: String
    public let label: String
    public let logName: String
    public let commandPreview: String
    public let rawCommand: String
    public let cwd: String?
    public let timeoutMilliseconds: Int?
    public let usageCount: Int
    public let configOrder: Int
    public let enabled: Bool
    public let allowAccessibility: Bool
    public let usesSelectedText: Bool
    public let runnableInHelper: Bool
    public let directKeyHint: String?
    public let statusTag: String?

    public init(
        id: String,
        slot: String,
        canonicalKeys: String,
        keyPills: [String],
        keyDisplay: String,
        keySearchAliases: String,
        label: String,
        logName: String? = nil,
        commandPreview: String,
        rawCommand: String,
        cwd: String?,
        timeoutMilliseconds: Int?,
        usageCount: Int,
        configOrder: Int,
        enabled: Bool,
        allowAccessibility: Bool,
        usesSelectedText: Bool,
        runnableInHelper: Bool,
        directKeyHint: String?,
        statusTag: String?
    ) {
        self.id = id
        self.slot = slot
        self.canonicalKeys = canonicalKeys
        self.keyPills = keyPills
        self.keyDisplay = keyDisplay
        self.keySearchAliases = keySearchAliases
        self.label = label
        self.logName = logName ?? label
        self.commandPreview = commandPreview
        self.rawCommand = rawCommand
        self.cwd = cwd
        self.timeoutMilliseconds = timeoutMilliseconds
        self.usageCount = usageCount
        self.configOrder = configOrder
        self.enabled = enabled
        self.allowAccessibility = allowAccessibility
        self.usesSelectedText = usesSelectedText
        self.runnableInHelper = runnableInHelper
        self.directKeyHint = directKeyHint
        self.statusTag = statusTag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.slot = try c.decode(String.self, forKey: .slot)
        self.canonicalKeys = try c.decode(String.self, forKey: .canonicalKeys)
        self.keyPills = try c.decode([String].self, forKey: .keyPills)
        self.keyDisplay = try c.decode(String.self, forKey: .keyDisplay)
        self.keySearchAliases = try c.decode(String.self, forKey: .keySearchAliases)
        self.label = try c.decode(String.self, forKey: .label)
        self.logName = try c.decodeIfPresent(String.self, forKey: .logName) ?? self.label
        self.commandPreview = try c.decode(String.self, forKey: .commandPreview)
        self.rawCommand = try c.decode(String.self, forKey: .rawCommand)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.timeoutMilliseconds = try c.decodeIfPresent(Int.self, forKey: .timeoutMilliseconds)
        self.usageCount = try c.decode(Int.self, forKey: .usageCount)
        self.configOrder = try c.decode(Int.self, forKey: .configOrder)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.allowAccessibility = try c.decode(Bool.self, forKey: .allowAccessibility)
        self.usesSelectedText = try c.decode(Bool.self, forKey: .usesSelectedText)
        self.runnableInHelper = try c.decode(Bool.self, forKey: .runnableInHelper)
        self.directKeyHint = try c.decodeIfPresent(String.self, forKey: .directKeyHint)
        self.statusTag = try c.decodeIfPresent(String.self, forKey: .statusTag)
    }
}

public struct PeekSearchSnapshot: Codable, Sendable, Equatable {
    public let totalCount: Int
    public let items: [PeekSearchItem]

    public init(totalCount: Int, items: [PeekSearchItem]) {
        self.totalCount = totalCount
        self.items = items
    }
}

/// Builds a frequency-ranked `PeekSearchSnapshot` from `Config` + optional `actions.log` history.
public enum PeekSearchBuilder {
    public static func buildSnapshot(
        from config: Config,
        logsDirectory: URL? = Paths.logs,
        showDisabledOverride: Bool? = nil,
        cachedUsageCounts: [String: Int]? = nil
    ) -> PeekSearchSnapshot {
        let includeDisabled = showDisabledOverride ?? config.peek.showDisabled
        let usageCounts: [String: Int]
        if let cachedUsageCounts {
            usageCounts = cachedUsageCounts
        } else if let logsDirectory {
            usageCounts = StatsAnalyzer.loadShortcutCounts(logsDirectory: logsDirectory)
        } else {
            usageCounts = [:]
        }

        var items: [PeekSearchItem] = []
        var order = 0

        for shortcut in config.shortcuts {
            if !includeDisabled && !shortcut.enabled {
                continue
            }
            let canonicalLower = StrictModes.sanitizeTerminalText(shortcut.keys.canonical).lowercased()
            let displayLower = StrictModes.sanitizeTerminalText(shortcut.displayName).lowercased()
            let usage: Int
            if canonicalLower == displayLower {
                usage = usageCounts[canonicalLower] ?? 0
            } else {
                usage = (usageCounts[displayLower] ?? 0) + (usageCounts[canonicalLower] ?? 0)
            }

            if let tap = shortcut.tap {
                items.append(makeItem(
                    shortcut: shortcut,
                    slot: "tap",
                    command: tap,
                    isDoubleTap: false,
                    usageCount: usage,
                    configOrder: order
                ))
                order += 1
            }
            if let doubleTap = shortcut.doubleTap {
                items.append(makeItem(
                    shortcut: shortcut,
                    slot: "doubleTap",
                    command: doubleTap,
                    isDoubleTap: true,
                    usageCount: usage,
                    configOrder: order
                ))
                order += 1
            }
        }

        // Default empty-query order: most-used first, falling back to config order.
        items.sort { lhs, rhs in
            if lhs.usageCount != rhs.usageCount {
                return lhs.usageCount > rhs.usageCount
            }
            return lhs.configOrder < rhs.configOrder
        }

        return PeekSearchSnapshot(totalCount: items.count, items: items)
    }

    private static func makeItem(
        shortcut: Shortcut,
        slot: String,
        command: String,
        isDoubleTap: Bool,
        usageCount: Int,
        configOrder: Int
    ) -> PeekSearchItem {
        let keyPills = KeycapFormatter.pills(for: shortcut.keys, isDoubleTap: isDoubleTap)
        let keyDisplay = KeycapFormatter.displayString(for: shortcut.keys, isDoubleTap: isDoubleTap)
        let usesSelected = SelectionReader.commandUsesSelectedText(command)
        let allowAX = shortcut.allowAccessibility
        let runnable = shortcut.enabled && !allowAX && !usesSelected

        let statusTag: String?
        let directHint: String?
        if !shortcut.enabled {
            statusTag = "off"
            directHint = "Disabled shortcut — enable with `hotkeyd enable \(shortcut.keys.canonical)`"
        } else if allowAX {
            statusTag = "AX"
            directHint = "Requires Accessibility — press \(keyDisplay) directly"
        } else if usesSelected {
            statusTag = "SEL"
            directHint = "Reads highlighted text — press \(keyDisplay) directly"
        } else {
            statusTag = nil
            directHint = nil
        }

        return PeekSearchItem(
            id: "\(shortcut.keys.canonical)#\(slot)",
            slot: slot,
            canonicalKeys: shortcut.keys.canonical,
            keyPills: keyPills,
            keyDisplay: keyDisplay,
            keySearchAliases: searchAliases(for: shortcut.keys, isDoubleTap: isDoubleTap),
            label: PeekLabeler.label(for: shortcut, command: command),
            logName: shortcut.displayName,
            commandPreview: safeCommandPreview(command),
            // Never transmit raw command/cwd/timeout over the pipe for non-runnable ([AX], [SEL],
            // or disabled) bindings; shrinks frames and keeps privileged/unrunnable commands out of helper RAM.
            rawCommand: runnable ? command : "",
            cwd: runnable ? shortcut.cwd : nil,
            timeoutMilliseconds: runnable ? shortcut.timeoutMilliseconds : nil,
            usageCount: usageCount,
            configOrder: configOrder,
            enabled: shortcut.enabled,
            allowAccessibility: allowAX,
            usesSelectedText: usesSelected,
            runnableInHelper: runnable,
            directKeyHint: directHint,
            statusTag: statusTag
        )
    }

    /// Sanitizes command preview and redacts credentials, query strings, webhook tokens, inline
    /// secret env assignments, and credential flags across both native URLs and shell commands.
    public static func safeCommandPreview(_ command: String) -> String {
        if case .url(let rawURL) = Action.migratedFromShellCommand(command) {
            let safeURL = PeekLabeler.redactURI(rawURL, includeScheme: true, stripWWW: false)
            return StrictModes.sanitizeTerminalText("open \(safeURL)", limit: 110)
        }
        return PeekLabeler.redactCommandPreview(command, limit: 110)
    }

    private static func searchAliases(for target: KeyTarget, isDoubleTap: Bool) -> String {
        var tokens: [String] = []
        func appendModifierAliases(_ mod: Modifier) {
            tokens.append(mod.token.lowercased())
            switch mod.family {
            case .command: tokens.append(contentsOf: ["cmd", "command"])
            case .option: tokens.append(contentsOf: ["opt", "option", "alt"])
            case .control: tokens.append(contentsOf: ["ctrl", "control"])
            case .shift: tokens.append("shift")
            case .fn: tokens.append(contentsOf: ["fn", "globe"])
            case .capsLock: tokens.append(contentsOf: ["caps", "capslock"])
            }
            if let side = mod.side {
                tokens.append(side == .left ? "left" : "right")
            }
        }

        switch target {
        case .modifier(let mod):
            appendModifierAliases(mod)
            tokens.append(contentsOf: ["double", "2x", "doubletap"])
        case .combo(let combo):
            for mod in combo.modifiers {
                appendModifierAliases(mod)
            }
            let keyName = KeyCodes.name(for: combo.keyCode).lowercased()
            tokens.append(keyName)
            if keyName == "escape" { tokens.append("esc") }
            if keyName == "return" { tokens.append("enter") }
            if keyName == "slash" { tokens.append("/") }
            if keyName == "backslash" { tokens.append("\\") }
            if isDoubleTap {
                tokens.append(contentsOf: ["double", "2x", "doubletap"])
            }
        case .sequence(let seq):
            appendModifierAliases(seq.leader)
            let keyName = KeyCodes.name(for: seq.keyCode).lowercased()
            tokens.append(keyName)
            if keyName == "escape" { tokens.append("esc") }
            if keyName == "slash" { tokens.append("/") }
            tokens.append("sequence")
        }

        return tokens.joined(separator: " ")
    }
}

/// Pure multi-token fuzzy search scorer across shortcut name/label, keys/aliases, and command.
public enum PeekSearchMatcher {
    public static let maxQueryCharacters = 128
    public static let maxQueryTokens = 12

    public static func filter(_ items: [PeekSearchItem], query: String) -> [PeekSearchItem] {
        let boundedQuery = query.count > maxQueryCharacters
            ? String(query.prefix(maxQueryCharacters))
            : query
        var seenTokens: Set<String> = []
        var tokens: [String] = []
        for piece in boundedQuery.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            let token = String(piece)
            if seenTokens.insert(token).inserted {
                tokens.append(token)
                if tokens.count >= maxQueryTokens {
                    break
                }
            }
        }

        guard !tokens.isEmpty else {
            return items
        }

        var scored: [(item: PeekSearchItem, score: Int)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            let labelLower = item.label.lowercased()
            let keysLower = "\(item.canonicalKeys.lowercased()) \(item.keyDisplay.lowercased()) \(item.keySearchAliases)"
            let cmdLower = item.commandPreview.lowercased()

            var totalScore = 0
            var matchedAllTokens = true

            for token in tokens {
                let labelScore = matchScore(token: token, in: labelLower, allowSubsequence: true).map { $0 * 3 }
                let keysScore = matchScore(token: token, in: keysLower, allowSubsequence: false).map { $0 * 2 }
                let cmdScore = matchScore(token: token, in: cmdLower, allowSubsequence: false)

                guard let best = [labelScore, keysScore, cmdScore].compactMap({ $0 }).max() else {
                    matchedAllTokens = false
                    break
                }
                totalScore += best
            }

            if matchedAllTokens {
                scored.append((item, totalScore))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.item.usageCount != rhs.item.usageCount {
                return lhs.item.usageCount > rhs.item.usageCount
            }
            return lhs.item.configOrder < rhs.item.configOrder
        }

        return scored.map(\.item)
    }

    private static func isWordBoundary(_ ch: Character) -> Bool {
        switch ch {
        case " ", "+", "›", "-", "/", "_", ".", ":":
            return true
        default:
            return false
        }
    }

    static func matchScore(token: String, in haystack: String, allowSubsequence: Bool = true) -> Int? {
        guard let firstTokenChar = token.first, !haystack.isEmpty else { return nil }
        if haystack == token {
            return 120
        }
        if haystack.hasPrefix(token) {
            return 100
        }

        // Check word-boundary prefix match (after space, +, ›, -, /, _, ., :) with O(1) first-char filter
        var prevWasBoundary = false
        var idx = haystack.startIndex
        while idx < haystack.endIndex {
            let ch = haystack[idx]
            if prevWasBoundary && ch == firstTokenChar && haystack[idx...].hasPrefix(token) {
                return 75
            }
            prevWasBoundary = isWordBoundary(ch)
            idx = haystack.index(after: idx)
        }

        if haystack.contains(token) {
            return 50
        }

        guard allowSubsequence else {
            return nil
        }

        // Ordered character subsequence match (fuzzy)
        var tIdx = token.startIndex
        var hIdx = haystack.startIndex
        var consecutive = 0
        var maxConsecutive = 0
        var lastMatched = false

        while tIdx < token.endIndex && hIdx < haystack.endIndex {
            if token[tIdx] == haystack[hIdx] {
                tIdx = token.index(after: tIdx)
                consecutive = lastMatched ? consecutive + 1 : 1
                maxConsecutive = max(maxConsecutive, consecutive)
                lastMatched = true
            } else {
                lastMatched = false
            }
            hIdx = haystack.index(after: hIdx)
        }

        guard tIdx == token.endIndex else {
            return nil
        }
        return 20 + min(15, maxConsecutive * 3)
    }
}

/// Zero-ANSI terminal renderer for `hotkeyd peek --search --terminal [--query <q>]`.
public enum PeekSearchTerminalFormatter {
    public static func format(_ snapshot: PeekSearchSnapshot, query: String) -> String {
        let filtered = PeekSearchMatcher.filter(snapshot.items, query: query)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        if trimmedQuery.isEmpty {
            lines.append("Hotkeyd Search (\(filtered.count) shortcut\(filtered.count == 1 ? "" : "s"), ranked by usage)")
        } else {
            lines.append("Hotkeyd Search '\(StrictModes.sanitizeTerminalText(trimmedQuery, limit: 40))' (\(filtered.count)/\(snapshot.totalCount))")
        }

        guard !filtered.isEmpty else {
            lines.append("")
            lines.append("  No matching shortcuts.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        let renderedRows: [(label: String, key: String, tag: String?, uses: Int)] = filtered.map { item in
            (
                label: StrictModes.sanitizeTerminalText(item.label),
                key: StrictModes.sanitizeTerminalText(item.keyDisplay),
                tag: item.statusTag.map { StrictModes.sanitizeTerminalText($0) }.flatMap { $0.isEmpty ? nil : $0 },
                uses: item.usageCount
            )
        }
        let maxLabelWidth = max(16, min(32, renderedRows.map(\.label.count).max() ?? 16))
        for row in renderedRows {
            let paddedLabel = row.label.count >= maxLabelWidth
                ? row.label
                : row.label + String(repeating: " ", count: maxLabelWidth - row.label.count)
            let tag = row.tag.map { " [\($0)]" } ?? ""
            let uses = row.uses > 0 ? " (\(row.uses)×)" : ""
            lines.append("  \(paddedLabel)  \(row.key)\(tag)\(uses)")
        }
        return lines.joined(separator: "\n")
    }
}
