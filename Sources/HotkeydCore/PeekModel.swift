import Foundation

/// Side-aware keycap formatting for the peek overlay and terminal quick-reference card.
///
/// Unlike `Modifier.glyph` (which maps both `lcmd` and `rcmd` to `⌘`), `KeycapFormatter` preserves
/// explicit left/right side distinctions (`L⌘`, `R⌘`) so side-specific bindings stay unambiguous.
public enum KeycapFormatter {
    private static let modifierOrder: [Modifier] = [
        .fn, .capsLock,
        .leftControl, .rightControl, .control,
        .leftOption, .rightOption, .option,
        .leftShift, .rightShift, .shift,
        .leftCommand, .rightCommand, .command
    ]

    public static func modifierLabel(_ modifier: Modifier) -> String {
        let sidePrefix: String
        switch modifier.side {
        case .left: sidePrefix = "L"
        case .right: sidePrefix = "R"
        case nil: sidePrefix = ""
        }
        switch modifier.family {
        case .command: return "\(sidePrefix)⌘"
        case .option: return "\(sidePrefix)⌥"
        case .control: return "\(sidePrefix)⌃"
        case .shift: return "\(sidePrefix)⇧"
        case .fn: return "fn"
        case .capsLock: return "⇪"
        }
    }

    public static func keyLabel(for keyCode: UInt16) -> String {
        let raw = KeyCodes.name(for: keyCode)
        switch raw {
        case "space": return "Space"
        case "return": return "↩"
        case "escape": return "Esc"
        case "tab": return "⇥"
        case "delete": return "⌫"
        case "forwarddelete": return "⌦"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "PgUp"
        case "pagedown": return "PgDn"
        case "slash": return "/"
        case "backslash": return "\\"
        case "comma": return ","
        case "period": return "."
        case "semicolon": return ";"
        case "quote": return "'"
        case "minus": return "-"
        case "equals": return "="
        case "leftbracket": return "["
        case "rightbracket": return "]"
        case "backtick": return "`"
        case "section": return "§"
        case "help": return "Help"
        default:
            return raw.uppercased()
        }
    }

    public static func orderedModifiers(_ modifiers: Set<Modifier>) -> [Modifier] {
        modifierOrder.filter { modifiers.contains($0) }
    }

    /// Individual visual tokens for a shortcut binding (`"›"` marks a two-step sequence separator,
    /// `"2×"` marks a double-tap gesture).
    public static func pills(for target: KeyTarget, isDoubleTap: Bool) -> [String] {
        switch target {
        case .modifier(let modifier):
            return [modifierLabel(modifier), "2×"]
        case .combo(let combo):
            var result = orderedModifiers(combo.modifiers).map(modifierLabel)
            result.append(keyLabel(for: combo.keyCode))
            if isDoubleTap {
                result.append("2×")
            }
            return result
        case .sequence(let sequence):
            return [modifierLabel(sequence.leader), "›", keyLabel(for: sequence.keyCode)]
        }
    }

    public static func displayString(for target: KeyTarget, isDoubleTap: Bool) -> String {
        switch target {
        case .modifier(let modifier):
            return "\(modifierLabel(modifier)) 2×"
        case .combo(let combo):
            let mods = orderedModifiers(combo.modifiers).map(modifierLabel)
            let key = keyLabel(for: combo.keyCode)
            let base = mods.isEmpty ? key : (mods + [key]).joined(separator: " + ")
            return isDoubleTap ? "\(base) 2×" : base
        case .sequence(let sequence):
            return "\(modifierLabel(sequence.leader)) › \(keyLabel(for: sequence.keyCode))"
        }
    }
}

/// Derives clean, privacy-safe display labels for shortcuts (including unnamed native apps,
/// query-redacted URLs, tilde paths, and truncated shell commands).
public enum PeekLabeler {
    public static let maxLabelLength = 36
    public static let maxShellPreviewLength = 32

    public static func label(for shortcut: Shortcut, command: String) -> String {
        if let rawName = shortcut.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawName.isEmpty {
            let clean = StrictModes.sanitizeTerminalText(rawName, limit: maxLabelLength)
            if !clean.isEmpty {
                return clean
            }
        }

        if let migrated = Action.migratedFromShellCommand(command) {
            switch migrated {
            case .app(let target, let arguments):
                var appTitle = target.trimmingCharacters(in: .whitespacesAndNewlines)
                if appTitle.contains("/") {
                    appTitle = URL(fileURLWithPath: appTitle).lastPathComponent
                }
                if appTitle.lowercased().hasSuffix(".app") {
                    appTitle = String(appTitle.dropLast(4))
                }
                if !arguments.isEmpty {
                    let argHint = redactCommandPreview(arguments.joined(separator: " "), limit: maxLabelLength)
                    if !argHint.isEmpty {
                        appTitle += " (\(argHint))"
                    }
                }
                return StrictModes.sanitizeTerminalText(appTitle, limit: maxLabelLength)

            case .url(let rawURL):
                return redactedURLLabel(rawURL)

            case .openPath(let rawPath):
                let home = Paths.realHomeDirectory.path
                let shortened: String
                if rawPath == home {
                    shortened = "~"
                } else if rawPath.hasPrefix(home + "/") {
                    shortened = "~" + String(rawPath.dropFirst(home.count))
                } else {
                    shortened = rawPath
                }
                return StrictModes.sanitizeTerminalText(shortened, limit: maxLabelLength)

            case .shell:
                break
            }
        }

        return redactCommandPreview(command, limit: maxShellPreviewLength)
    }

    /// Displays host and redacted non-empty path only — strictly stripping userinfo, query strings,
    /// fragments, and webhook/token path segments so secrets never flash on screen (even for
    /// malformed URLs).
    public static func redactedURLLabel(_ rawURL: String) -> String {
        let redacted = redactURI(rawURL, includeScheme: false, stripWWW: true)
        return StrictModes.sanitizeTerminalText(redacted, limit: maxLabelLength)
    }

    /// Linear-time command preview redactor used by both `PeekLabeler` and `PeekSearchBuilder`.
    /// Truncates multi-line commands to the first non-empty line, strips credentials/queries/
    /// fragments/webhook tokens from all inline `scheme://...` URIs, and redacts common secret env
    /// assignments, Bearer/Basic headers, CLI credential flags, and high-confidence key prefixes.
    public static func redactCommandPreview(_ raw: String, limit: Int) -> String {
        let rawLines = raw.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
        let nonEmptyLines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let firstLine = nonEmptyLines.first else { return "" }
        let hasMoreLines = nonEmptyLines.count > 1

        let urisRedacted = redactInlineURIs(in: firstLine)
        let tokensRedacted = redactShellSecrets(in: urisRedacted)
        let preview = hasMoreLines ? "\(tokensRedacted) …" : tokensRedacted
        return StrictModes.sanitizeTerminalText(preview, limit: limit)
    }

    /// Redacts a single URI (valid or malformed), preserving its actual scheme when requested and
    /// stripping userinfo (`user:pass@`), query strings, fragments, and sensitive path token segments.
    public static func redactURI(_ rawURI: String, includeScheme: Bool, stripWWW: Bool) -> String {
        let trimmed = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeSep = trimmed.range(of: "://") else {
            return "[REDACTED]"
        }
        let scheme = String(trimmed[..<schemeSep.lowerBound]).lowercased()

        if let components = URLComponents(string: trimmed),
           let rawHost = components.host,
           !rawHost.isEmpty {
            let host = (stripWWW && rawHost.lowercased().hasPrefix("www."))
                ? String(rawHost.dropFirst(4))
                : rawHost
            let hostAndPort: String
            if includeScheme, let port = components.port {
                hostAndPort = "\(host):\(port)"
            } else {
                hostAndPort = host
            }
            let safePath = redactPathSegments(components.path)
            let combined = safePath.isEmpty ? hostAndPort : "\(hostAndPort)/\(safePath)"
            return includeScheme ? "\(scheme)://\(combined)" : combined
        }

        // Malformed URI fallback: never echo raw userinfo, query, or fragment.
        var remainder = String(trimmed[schemeSep.upperBound...])
        if let cut = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            remainder = String(remainder[..<cut])
        }
        let authorityRaw: String
        let pathRaw: String
        if let slash = remainder.firstIndex(of: "/") {
            authorityRaw = String(remainder[..<slash])
            pathRaw = String(remainder[slash...])
        } else {
            authorityRaw = remainder
            pathRaw = ""
        }

        var safeAuthority = authorityRaw
        if let lastAt = safeAuthority.lastIndex(of: "@") {
            safeAuthority = String(safeAuthority[safeAuthority.index(after: lastAt)...])
        }
        let authorityInvalid = safeAuthority.isEmpty
            || safeAuthority.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" || $0 == "'" || $0 == "\"" })
        if authorityInvalid {
            return includeScheme ? "\(scheme)://[REDACTED]" : "[REDACTED]"
        }
        if stripWWW && safeAuthority.lowercased().hasPrefix("www.") {
            safeAuthority = String(safeAuthority.dropFirst(4))
        }
        let safePath = redactPathSegments(pathRaw)
        let combined = safePath.isEmpty ? safeAuthority : "\(safeAuthority)/\(safePath)"
        return includeScheme ? "\(scheme)://\(combined)" : combined
    }

    // MARK: - Redaction Helpers

    private static let secretPathKeywords: Set<String> = [
        "token", "tokens", "key", "keys", "secret", "secrets", "auth",
        "password", "apikey", "api_key", "api-key", "webhook", "webhooks", "bearer"
    ]

    private static let secretKeyComponents: Set<String> = [
        "TOKEN", "SECRET", "KEY", "APIKEY", "PASS", "PASSWD", "PASSWORD", "PWD",
        "AUTH", "AUTHORIZATION", "COOKIE", "CRED", "CREDS", "CREDENTIAL",
        "CREDENTIALS", "JWT", "BEARER", "WEBHOOK", "DSN", "PRIVATE", "SESSION", "PAT"
    ]

    private static let alwaysSecretLongFlags: Set<String> = [
        "--password", "--passwd", "--pass", "--token", "--access-token",
        "--refresh-token", "--id-token", "--api-key", "--apikey", "--secret",
        "--client-secret", "--auth", "--bearer", "--private-key", "--cookie",
        "--proxy-user", "--user"
    ]

    private static let credentialCommands: Set<String> = [
        "curl", "wget", "http", "https", "mysql", "mysqldump", "psql", "redis-cli", "sshpass"
    ]

    private static let passwordFlagCommands: Set<String> = [
        "sshpass", "mysql", "mysqldump", "redis-cli", "unzip", "7z", "gpg", "openssl", "security"
    ]

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-api-key", "x-auth-token", "x-token", "x-secret", "api-key", "apikey", "x-access-token"
    ]

    private static let knownSecretPrefixes: [String] = [
        "sk-", "sk_live_", "sk_test_", "pk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "github_pat_", "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "AIza", "AKIA", "ASIA",
        "glpat-", "npm_"
    ]

    private static func isASCIISchemeChar(_ c: Character, isFirst: Bool) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        let v = scalar.value
        let isAlpha = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
        if isFirst { return isAlpha }
        let isDigit = (v >= 0x30 && v <= 0x39)
        return isAlpha || isDigit || v == 0x2B || v == 0x2D || v == 0x2E // +, -, .
    }

    private static func isURITerminator(_ c: Character) -> Bool {
        c.isWhitespace || c == "'" || c == "\"" || c == "`"
            || c == "<" || c == ">" || c == ")" || c == "]" || c == "}"
            || c == ";" || c == "|" || c == "&"
    }

    private static func redactInlineURIs(in text: String) -> String {
        guard text.contains("://") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex

        while let sepRange = text.range(of: "://", range: cursor..<text.endIndex) {
            var schemeStart = sepRange.lowerBound
            while schemeStart > cursor {
                let prev = text.index(before: schemeStart)
                if isASCIISchemeChar(text[prev], isFirst: false) {
                    schemeStart = prev
                } else {
                    break
                }
            }
            let validScheme = schemeStart < sepRange.lowerBound
                && isASCIISchemeChar(text[schemeStart], isFirst: true)
            guard validScheme else {
                output.append(contentsOf: text[cursor..<sepRange.upperBound])
                cursor = sepRange.upperBound
                continue
            }

            var uriEnd = sepRange.upperBound
            while uriEnd < text.endIndex && !isURITerminator(text[uriEnd]) {
                uriEnd = text.index(after: uriEnd)
            }

            output.append(contentsOf: text[cursor..<schemeStart])
            let uriSlice = String(text[schemeStart..<uriEnd])
            output.append(redactURI(uriSlice, includeScheme: true, stripWWW: false))
            cursor = uriEnd
        }

        output.append(contentsOf: text[cursor..<text.endIndex])
        return output
    }

    private static func redactPathSegments(_ rawPath: String) -> String {
        let segs = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segs.isEmpty else { return "" }

        // Slack incoming webhook: /services/T.../B.../...
        if segs.count >= 4
            && segs[0].lowercased() == "services"
            && segs[1].hasPrefix("T")
            && segs[2].hasPrefix("B") {
            return "services/[REDACTED]"
        }
        // Discord webhook: /api/webhooks/<id>/<token>
        if segs.count >= 4
            && segs[0].lowercased() == "api"
            && segs[1].lowercased() == "webhooks" {
            return "api/webhooks/[REDACTED]"
        }

        var result: [String] = []
        result.reserveCapacity(segs.count)
        var redactNext = false
        for seg in segs {
            if redactNext {
                result.append("[REDACTED]")
                redactNext = false
                continue
            }
            if seg.lowercased().hasPrefix("bot") && seg.contains(":") {
                result.append("bot[REDACTED]")
                continue
            }
            if looksLikeSecretValue(seg) {
                result.append("[REDACTED]")
                continue
            }
            result.append(seg)
            if secretPathKeywords.contains(seg.lowercased()) {
                redactNext = true
            }
        }
        return result.joined(separator: "/")
    }

    private static func looksLikeSecretValue(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !value.isEmpty else { return false }
        for prefix in knownSecretPrefixes where value.hasPrefix(prefix) && value.count > prefix.count + 3 {
            return true
        }
        // JWT structure: eyJ<header>.<payload>.<sig>
        if value.hasPrefix("eyJ") {
            let dotParts = value.split(separator: ".", omittingEmptySubsequences: false)
            if dotParts.count == 3 && dotParts[0].count >= 4 && dotParts[1].count >= 4 && !dotParts[2].isEmpty {
                return true
            }
        }
        return false
    }

    private static func isSecretKeyName(_ rawKey: String) -> Bool {
        let trimmed = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "-'\"")).uppercased()
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.split { $0 == "_" || $0 == "-" }.map(String.init)
        return parts.contains { secretKeyComponents.contains($0) }
    }

    private static func redactBearerOrBasic(in value: String) -> String {
        var result = value
        for scheme in ["Bearer ", "bearer ", "BEARER ", "Basic ", "basic ", "BASIC "] {
            var searchStart = result.startIndex
            while let range = result.range(of: scheme, range: searchStart..<result.endIndex) {
                let valueStart = range.upperBound
                var valueEnd = valueStart
                while valueEnd < result.endIndex && !result[valueEnd].isWhitespace
                    && result[valueEnd] != "'" && result[valueEnd] != "\"" && result[valueEnd] != ";" {
                    valueEnd = result.index(after: valueEnd)
                }
                guard valueEnd > valueStart else {
                    searchStart = range.upperBound
                    continue
                }
                let replacement = "[REDACTED]"
                result.replaceSubrange(valueStart..<valueEnd, with: replacement)
                searchStart = result.index(valueStart, offsetBy: replacement.count, limitedBy: result.endIndex) ?? result.endIndex
            }
        }
        return result
    }

    private static func redactShellSecrets(in line: String) -> String {
        struct Segment {
            let leading: String
            let rawToken: String
            let isOperator: Bool
        }

        // Tokenize preserving exact separators and single/double-quoted spans.
        var segments: [Segment] = []
        var idx = line.startIndex
        while idx < line.endIndex {
            let wsStart = idx
            while idx < line.endIndex && line[idx].isWhitespace {
                idx = line.index(after: idx)
            }
            let leading = String(line[wsStart..<idx])
            guard idx < line.endIndex else {
                if !leading.isEmpty {
                    segments.append(Segment(leading: leading, rawToken: "", isOperator: false))
                }
                break
            }

            let ch = line[idx]
            if ch == ";" || ch == "|" || ch == "&" {
                let opStart = idx
                idx = line.index(after: idx)
                if idx < line.endIndex && (ch == "|" || ch == "&") && line[idx] == ch {
                    idx = line.index(after: idx)
                }
                segments.append(Segment(leading: leading, rawToken: String(line[opStart..<idx]), isOperator: true))
                continue
            }

            let tokStart = idx
            var quote: Character?
            var escaped = false
            while idx < line.endIndex {
                let c = line[idx]
                if let q = quote {
                    if q == "\"" && escaped {
                        escaped = false
                    } else if q == "\"" && c == "\\" {
                        escaped = true
                    } else if c == q {
                        quote = nil
                    }
                    idx = line.index(after: idx)
                } else {
                    if c.isWhitespace || c == ";" || c == "|" || c == "&" {
                        break
                    }
                    if c == "'" || c == "\"" {
                        quote = c
                    }
                    idx = line.index(after: idx)
                }
            }
            segments.append(Segment(leading: leading, rawToken: String(line[tokStart..<idx]), isOperator: false))
        }

        func stripOuterQuotes(_ token: String) -> (quote: Character?, inner: String) {
            guard token.count >= 2 else { return (nil, token) }
            if token.first == "\"" && token.last == "\"" {
                return ("\"", String(token.dropFirst().dropLast()))
            }
            if token.first == "'" && token.last == "'" {
                return ("'", String(token.dropFirst().dropLast()))
            }
            return (nil, token)
        }

        func wrap(_ inner: String, quote: Character?) -> String {
            guard let quote else { return inner }
            return "\(quote)\(inner)\(quote)"
        }

        var output = ""
        output.reserveCapacity(line.count)
        var currentCmd: String?
        var expectSecretValue = false
        var expectHeader = false

        for i in 0..<segments.count {
            let seg = segments[i]
            output.append(seg.leading)
            guard !seg.rawToken.isEmpty else { continue }

            if seg.isOperator {
                output.append(seg.rawToken)
                currentCmd = nil
                expectSecretValue = false
                expectHeader = false
                continue
            }

            let (quote, inner) = stripOuterQuotes(seg.rawToken)
            let lower = inner.lowercased()

            if expectSecretValue {
                expectSecretValue = false
                output.append(wrap("[REDACTED]", quote: quote))
                continue
            }

            if expectHeader {
                expectHeader = false
                var redactedHeader = redactBearerOrBasic(in: inner)
                if let colon = redactedHeader.firstIndex(of: ":") {
                    let headerName = redactedHeader[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if sensitiveHeaderNames.contains(headerName) {
                        redactedHeader = "\(redactedHeader[...colon]) [REDACTED]"
                    }
                }
                output.append(wrap(redactedHeader, quote: quote))
                continue
            }

            if lower == "bearer" || lower == "basic" {
                output.append(seg.rawToken)
                expectSecretValue = true
                continue
            }

            // Inline KEY=VALUE or --flag=VALUE (skip URIs, already handled).
            if let eq = inner.firstIndex(of: "="), eq > inner.startIndex, !inner.contains("://") {
                let lhs = String(inner[..<eq])
                let rhs = String(inner[inner.index(after: eq)...])
                if isSecretKeyName(lhs) || looksLikeSecretValue(rhs) {
                    output.append(wrap("\(lhs)=[REDACTED]", quote: quote))
                    continue
                }
            }

            if alwaysSecretLongFlags.contains(lower) {
                output.append(seg.rawToken)
                expectSecretValue = true
                continue
            }

            if inner == "-H" || lower == "--header" {
                output.append(seg.rawToken)
                expectHeader = true
                continue
            }

            if inner == "-u" {
                let nextHasColon: Bool
                if i + 1 < segments.count && !segments[i + 1].isOperator {
                    nextHasColon = stripOuterQuotes(segments[i + 1].rawToken).inner.contains(":")
                } else {
                    nextHasColon = false
                }
                output.append(seg.rawToken)
                if nextHasColon || (currentCmd.map { credentialCommands.contains($0) } ?? false) {
                    expectSecretValue = true
                }
                continue
            }

            if inner.hasPrefix("-u") && inner.count > 2 && inner.contains(":") {
                output.append(wrap("-u[REDACTED]", quote: quote))
                continue
            }

            if let cmd = currentCmd, passwordFlagCommands.contains(cmd) {
                if inner == "-p" || (cmd == "redis-cli" && inner == "-a") {
                    output.append(seg.rawToken)
                    expectSecretValue = true
                    continue
                }
                if inner.hasPrefix("-p") && inner.count > 2 {
                    output.append(wrap("-p[REDACTED]", quote: quote))
                    continue
                }
            }

            let bearerCleaned = redactBearerOrBasic(in: inner)
            if bearerCleaned != inner {
                output.append(wrap(bearerCleaned, quote: quote))
                continue
            }

            if looksLikeSecretValue(inner) {
                output.append(wrap("[REDACTED]", quote: quote))
                continue
            }

            output.append(seg.rawToken)

            if currentCmd == nil {
                let wrappers: Set<String> = ["export", "env", "sudo", "nohup", "time", "command"]
                if !wrappers.contains(lower) && !inner.contains("=") {
                    currentCmd = URL(fileURLWithPath: inner).lastPathComponent.lowercased()
                }
            }
        }

        return output
    }
}

public enum PeekTriggerFamily: String, Codable, Sendable, CaseIterable {
    case fnCombos
    case fnSequences
    case capsCombos
    case capsSequences
    case doubleTapModifiers
    case other

    public var title: String {
        switch self {
        case .fnCombos: return "fn + …"
        case .fnSequences: return "fn › …"
        case .capsCombos: return "⇪ Caps Lock + …"
        case .capsSequences: return "⇪ Caps Lock › …"
        case .doubleTapModifiers: return "Double-Tap Modifiers"
        case .other: return "Other Shortcuts"
        }
    }

    public static func classify(_ target: KeyTarget) -> PeekTriggerFamily {
        switch target {
        case .modifier:
            return .doubleTapModifiers
        case .combo(let combo):
            if combo.modifiers.contains(.fn) {
                return .fnCombos
            }
            if combo.modifiers.contains(.capsLock) {
                return .capsCombos
            }
            return .other
        case .sequence(let sequence):
            if sequence.leader == .fn {
                return .fnSequences
            }
            if sequence.leader == .capsLock {
                return .capsSequences
            }
            return .other
        }
    }
}

public enum PeekMode: String, Codable, Sendable, Equatable {
    case hold
    case pinned
}

public struct PeekEntry: Codable, Sendable, Equatable {
    public let keyPills: [String]
    public let keyDisplay: String
    public let canonicalKeys: String
    public let label: String
    public let badges: [String]
    public let isDoubleTap: Bool
    public let enabled: Bool
    public let matched: Bool

    public init(
        keyPills: [String],
        keyDisplay: String,
        canonicalKeys: String,
        label: String,
        badges: [String],
        isDoubleTap: Bool,
        enabled: Bool,
        matched: Bool = true
    ) {
        self.keyPills = keyPills
        self.keyDisplay = keyDisplay
        self.canonicalKeys = canonicalKeys
        self.label = label
        self.badges = badges
        self.isDoubleTap = isDoubleTap
        self.enabled = enabled
        self.matched = matched
    }

    private enum CodingKeys: String, CodingKey {
        case keyPills, keyDisplay, canonicalKeys, label, badges, isDoubleTap, enabled, matched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyPills = try c.decode([String].self, forKey: .keyPills)
        keyDisplay = try c.decode(String.self, forKey: .keyDisplay)
        canonicalKeys = try c.decode(String.self, forKey: .canonicalKeys)
        label = try c.decode(String.self, forKey: .label)
        badges = try c.decode([String].self, forKey: .badges)
        isDoubleTap = try c.decode(Bool.self, forKey: .isDoubleTap)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        matched = try c.decodeIfPresent(Bool.self, forKey: .matched) ?? true
    }
}

public struct PeekGroup: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let entries: [PeekEntry]
    public let highlighted: Bool

    public init(id: String, title: String, entries: [PeekEntry], highlighted: Bool) {
        self.id = id
        self.title = title
        self.entries = entries
        self.highlighted = highlighted
    }
}

public struct PeekSnapshot: Codable, Sendable, Equatable {
    public let mode: PeekMode
    public let title: String
    public let subtitle: String?
    public let activeModifierLabels: [String]
    public let matchedCount: Int
    public let totalCount: Int
    public let dimUnmatched: Bool
    public let groups: [PeekGroup]

    public init(
        mode: PeekMode,
        title: String,
        subtitle: String?,
        activeModifierLabels: [String],
        matchedCount: Int,
        totalCount: Int,
        dimUnmatched: Bool = true,
        groups: [PeekGroup]
    ) {
        self.mode = mode
        self.title = title
        self.subtitle = subtitle
        self.activeModifierLabels = activeModifierLabels
        self.matchedCount = matchedCount
        self.totalCount = totalCount
        self.dimUnmatched = dimUnmatched
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case mode, title, subtitle, activeModifierLabels, matchedCount, totalCount, dimUnmatched, groups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(PeekMode.self, forKey: .mode)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        activeModifierLabels = try c.decode([String].self, forKey: .activeModifierLabels)
        matchedCount = try c.decode(Int.self, forKey: .matchedCount)
        totalCount = try c.decode(Int.self, forKey: .totalCount)
        dimUnmatched = try c.decodeIfPresent(Bool.self, forKey: .dimUnmatched) ?? true
        groups = try c.decode([PeekGroup].self, forKey: .groups)
    }
}

/// Pure, UI-free builder that converts a `Config` + active held modifiers into a smart-focus
/// `PeekSnapshot` suitable for both the AppKit HUD helper and the terminal card.
public enum PeekModel {
    private struct ExpandedItem {
        let family: PeekTriggerFamily
        let target: KeyTarget
        let entry: PeekEntry
    }

    /// Returns `true` when physical modifier `held` satisfies binding requirement `required`
    /// (exact match, or `required` is side-agnostic for the same modifier family).
    public static func modifier(_ held: Modifier, satisfies required: Modifier) -> Bool {
        if held == required { return true }
        return required.side == nil && held.family == required.family
    }

    /// Smart-focus & live-narrowing matcher:
    /// - Empty `heldModifiers` (pinned mode) matches everything.
    /// - Single held modifier matches combos using that modifier, sequences led by it, and bare
    ///   double-taps of that modifier.
    /// - Multiple held modifiers (live-narrowing, e.g. `fn + lshift`) match only combos whose
    ///   required modifiers include every held modifier (narrowing down to `fn+shift+...`).
    public static func matches(target: KeyTarget, heldModifiers: Set<Modifier>) -> Bool {
        guard !heldModifiers.isEmpty else { return true }

        if heldModifiers.count == 1, let single = heldModifiers.first {
            switch target {
            case .modifier(let mod):
                return modifier(single, satisfies: mod)
            case .combo(let combo):
                return combo.modifiers.contains { modifier(single, satisfies: $0) }
            case .sequence(let sequence):
                return modifier(single, satisfies: sequence.leader)
            }
        }

        // Live-narrowing: require every held modifier to be present in a combo's modifier set.
        guard case .combo(let combo) = target else { return false }
        for heldMod in heldModifiers {
            guard combo.modifiers.contains(where: { modifier(heldMod, satisfies: $0) }) else {
                return false
            }
        }
        return true
    }

    public static func buildSnapshot(
        from config: Config,
        mode: PeekMode,
        heldModifiers: Set<Modifier> = [],
        showDisabledOverride: Bool? = nil
    ) -> PeekSnapshot {
        let includeDisabled = showDisabledOverride ?? config.peek.showDisabled
        var items: [ExpandedItem] = []

        for shortcut in config.shortcuts {
            if !includeDisabled && !shortcut.enabled {
                continue
            }
            let family = PeekTriggerFamily.classify(shortcut.keys)
            var baseBadges: [String] = []
            if !shortcut.enabled { baseBadges.append("disabled") }
            if shortcut.allowAccessibility { baseBadges.append("AX") }
            if shortcut.passThrough { baseBadges.append("pass") }

            if let tap = shortcut.tap {
                let entry = PeekEntry(
                    keyPills: KeycapFormatter.pills(for: shortcut.keys, isDoubleTap: false),
                    keyDisplay: KeycapFormatter.displayString(for: shortcut.keys, isDoubleTap: false),
                    canonicalKeys: shortcut.keys.canonical,
                    label: PeekLabeler.label(for: shortcut, command: tap),
                    badges: baseBadges,
                    isDoubleTap: false,
                    enabled: shortcut.enabled
                )
                items.append(ExpandedItem(family: family, target: shortcut.keys, entry: entry))
            }
            if let doubleTap = shortcut.doubleTap {
                let entry = PeekEntry(
                    keyPills: KeycapFormatter.pills(for: shortcut.keys, isDoubleTap: true),
                    keyDisplay: KeycapFormatter.displayString(for: shortcut.keys, isDoubleTap: true),
                    canonicalKeys: shortcut.keys.canonical,
                    label: PeekLabeler.label(for: shortcut, command: doubleTap),
                    badges: baseBadges,
                    isDoubleTap: true,
                    enabled: shortcut.enabled
                )
                items.append(ExpandedItem(family: family, target: shortcut.keys, entry: entry))
            }
        }

        let orderedHeld = KeycapFormatter.orderedModifiers(heldModifiers)
        let activeLabels = orderedHeld.map(KeycapFormatter.modifierLabel)
        let totalCount = items.count

        // Hold-peek (e.g. holding `fn`): calm full-brightness overview of all shortcuts with zero
        // modifier bias. Tapping Tab pins the overlay so any modifier can spotlight related keys.
        if mode == .hold {
            let groups = buildGroups(from: items, spotlightHeld: nil)
            let subtitle: String?
            if totalCount == 0 {
                subtitle = "No shortcuts configured yet — add one with `hotkeyd add`"
            } else {
                subtitle = "Release to hide · Tab to pin · press key to run"
            }
            return PeekSnapshot(
                mode: .hold,
                title: "Shortcuts",
                subtitle: subtitle,
                activeModifierLabels: activeLabels,
                matchedCount: totalCount,
                totalCount: totalCount,
                dimUnmatched: false,
                groups: groups
            )
        }

        // Pinned mode with no modifier held: all shortcuts at 100% brightness.
        if orderedHeld.isEmpty {
            let groups = buildGroups(from: items, spotlightHeld: nil)
            let subtitle: String?
            if totalCount == 0 {
                subtitle = "No shortcuts configured yet — add one with `hotkeyd add`"
            } else {
                subtitle = "Esc to close · Hold any modifier to show related shortcuts · / to search · Click anywhere"
            }
            return PeekSnapshot(
                mode: .pinned,
                title: "Hotkeyd Shortcuts",
                subtitle: subtitle,
                activeModifierLabels: [],
                matchedCount: totalCount,
                totalCount: totalCount,
                dimUnmatched: false,
                groups: groups
            )
        }

        // Pinned mode + modifier held: keep every card in its exact deterministic place and
        // spotlight matching entries/cards in place (zero layout jump).
        let heldDescription = activeLabels.joined(separator: " + ")
        let groups = buildGroups(from: items, spotlightHeld: heldModifiers)
        let matchedCount = groups
            .flatMap(\.entries)
            .filter(\.matched)
            .count

        let subtitle: String?
        if totalCount == 0 {
            subtitle = "No shortcuts configured yet — add one with `hotkeyd add`"
        } else if matchedCount == 0 {
            subtitle = "No shortcuts for \(heldDescription) · Release to show all"
        } else {
            subtitle = "Release to show all · Press key to run · Esc to close"
        }

        return PeekSnapshot(
            mode: .pinned,
            title: "Related to \(heldDescription)",
            subtitle: subtitle,
            activeModifierLabels: activeLabels,
            matchedCount: matchedCount,
            totalCount: totalCount,
            dimUnmatched: config.peek.dimUnmatched,
            groups: groups
        )
    }

    private static func buildGroups(
        from items: [ExpandedItem],
        spotlightHeld: Set<Modifier>?
    ) -> [PeekGroup] {
        var result: [PeekGroup] = []
        for family in PeekTriggerFamily.allCases {
            let familyItems = items.filter { $0.family == family }
            guard !familyItems.isEmpty else { continue }
            let entries: [PeekEntry]
            let groupHighlighted: Bool
            if let spotlightHeld {
                entries = familyItems.map { item in
                    let isMatch = matches(target: item.target, heldModifiers: spotlightHeld)
                    return PeekEntry(
                        keyPills: item.entry.keyPills,
                        keyDisplay: item.entry.keyDisplay,
                        canonicalKeys: item.entry.canonicalKeys,
                        label: item.entry.label,
                        badges: item.entry.badges,
                        isDoubleTap: item.entry.isDoubleTap,
                        enabled: item.entry.enabled,
                        matched: isMatch
                    )
                }
                groupHighlighted = entries.contains(where: \.matched)
            } else {
                entries = familyItems.map(\.entry)
                groupHighlighted = true
            }
            result.append(PeekGroup(
                id: family.rawValue,
                title: family.title,
                entries: entries,
                highlighted: groupHighlighted
            ))
        }
        return result
    }
}

/// Bounded newline-delimited JSON protocol sent from the daemon (`controlQueue`) to the
/// TCC-disclaimed UI helper subprocess (`hotkeyd __peek-overlay`) over an unnamed `pipe(2)`.
public enum PeekWireMessage: Codable, Sendable, Equatable {
    public static let maxFrameBytes: Int = 262_144

    case show(PeekSnapshot)
    case toggleSearch(PeekSearchSnapshot)
    case hide
    case quit

    private enum CodingKeys: String, CodingKey {
        case op
        case snapshot
        case search
    }

    private enum Op: String, Codable {
        case show
        case toggleSearch
        case hide
        case quit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(Op.self, forKey: .op)
        switch op {
        case .show:
            self = .show(try container.decode(PeekSnapshot.self, forKey: .snapshot))
        case .toggleSearch:
            self = .toggleSearch(try container.decode(PeekSearchSnapshot.self, forKey: .search))
        case .hide:
            self = .hide
        case .quit:
            self = .quit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .show(let snapshot):
            try container.encode(Op.show, forKey: .op)
            try container.encode(snapshot, forKey: .snapshot)
        case .toggleSearch(let search):
            try container.encode(Op.toggleSearch, forKey: .op)
            try container.encode(search, forKey: .search)
        case .hide:
            try container.encode(Op.hide, forKey: .op)
        case .quit:
            try container.encode(Op.quit, forKey: .op)
        }
    }

    /// Encodes a single NDJSON line (`...\n`) and rejects oversized frames above `maxFrameBytes`.
    public func encodeLine() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A)
        guard data.count <= Self.maxFrameBytes else { return nil }
        return data
    }

    public static func decodeLine(_ rawLine: Data) -> PeekWireMessage? {
        guard !rawLine.isEmpty, rawLine.count <= maxFrameBytes else { return nil }
        return try? JSONDecoder().decode(PeekWireMessage.self, from: rawLine)
    }
}

/// Zero-ANSI, zero-termios terminal quick-reference card renderer for `hotkeyd peek --terminal`.
public enum PeekTerminalFormatter {
    public static func format(_ snapshot: PeekSnapshot, config: PeekConfig? = nil) -> String {
        var lines: [String] = []
        let countLabel = snapshot.totalCount == 1 ? "1 shortcut" : "\(snapshot.totalCount) shortcuts"
        let cleanTitle = StrictModes.sanitizeTerminalText(snapshot.title)
        lines.append("\(cleanTitle) (\(countLabel))")

        if snapshot.groups.isEmpty {
            lines.append("")
            lines.append("  No shortcuts to display.")
            lines.append("  Add one with: hotkeyd add lcmd 'open -a Terminal'")
            return lines.joined(separator: "\n")
        }

        let sanitizedGroups: [(title: String, entries: [(key: String, label: String, badges: [String])])] = snapshot.groups.map { group in
            let gTitle = StrictModes.sanitizeTerminalText(group.title)
            let gEntries = group.entries.map { entry in
                (
                    key: StrictModes.sanitizeTerminalText(entry.keyDisplay),
                    label: StrictModes.sanitizeTerminalText(entry.label),
                    badges: entry.badges.map { StrictModes.sanitizeTerminalText($0) }.filter { !$0.isEmpty }
                )
            }
            return (gTitle, gEntries)
        }

        let maxKeyWidth = max(
            10,
            min(
                24,
                sanitizedGroups
                    .flatMap(\.entries)
                    .map { $0.key.count }
                    .max() ?? 10
            )
        )

        for group in sanitizedGroups {
            lines.append("")
            lines.append(group.title)
            for entry in group.entries {
                let paddedKey = entry.key.count >= maxKeyWidth
                    ? entry.key
                    : entry.key + String(repeating: " ", count: maxKeyWidth - entry.key.count)
                let badgeSuffix = entry.badges.isEmpty ? "" : "  [\(entry.badges.joined(separator: ", "))]"
                lines.append("  \(paddedKey)  \(entry.label)\(badgeSuffix)")
            }
        }

        if let config {
            lines.append("")
            let triggersText = config.triggers.isEmpty
                ? "none"
                : config.triggers.map(KeycapFormatter.modifierLabel).joined(separator: ", ")
            var footer = "peek overlay: \(config.enabled ? "enabled" : "disabled") · hold \(triggersText) (\(config.delayMilliseconds)ms)"
            if let toggle = config.toggle {
                let toggleDisplay = KeycapFormatter.displayString(for: toggle, isDoubleTap: toggle.modifier != nil)
                footer += " · toggle \(toggleDisplay)"
            }
            if let searchToggle = config.searchToggle {
                let searchDisplay = KeycapFormatter.displayString(for: searchToggle, isDoubleTap: searchToggle.modifier != nil)
                footer += " · search \(searchDisplay)"
            }
            lines.append(footer)
        }

        return lines.joined(separator: "\n")
    }
}
