import Foundation

public enum CompletionShell: String, Codable, Sendable, CaseIterable {
    case zsh
    case bash
    case fish
}

public enum ShortcutCompletionFilter: String, Sendable {
    case all
    case enabledOnly
    case disabledOnly
}

public struct CompletionCandidate: Codable, Sendable, Equatable {
    public let value: String
    public let description: String

    public init(value: String, description: String) {
        self.value = value
        self.description = description
    }
}

public enum ShellCompletions {
    // MARK: - Dynamic completion providers

    public static func shortcutCandidates(
        from config: Config,
        filter: ShortcutCompletionFilter = .all
    ) -> [CompletionCandidate] {
        var result: [CompletionCandidate] = []
        var seen: Set<String> = []

        for shortcut in config.shortcuts {
            switch filter {
            case .all:
                break
            case .enabledOnly:
                guard shortcut.enabled else { continue }
            case .disabledOnly:
                guard !shortcut.enabled else { continue }
            }

            let canonical = sanitizeField(shortcut.keys.canonical, limit: 80)
            let commandPreview = sanitizeField(primaryCommandPreview(for: shortcut), limit: 56)
            let stateTag = shortcut.enabled ? "" : "[disabled] "

            if !canonical.isEmpty, seen.insert(canonical).inserted {
                let label: String
                if let explicitName = shortcut.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !explicitName.isEmpty,
                   explicitName != canonical {
                    label = "\(stateTag)\(sanitizeField(explicitName, limit: 28)): \(commandPreview)"
                } else {
                    label = "\(stateTag)\(commandPreview)"
                }
                result.append(CompletionCandidate(value: canonical, description: sanitizeField(label, limit: 72)))
            }

            if let rawName = shortcut.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawName.isEmpty {
                let cleanName = sanitizeField(rawName, limit: 80)
                if !cleanName.isEmpty, seen.insert(cleanName).inserted {
                    let label = "\(stateTag)\(canonical): \(commandPreview)"
                    result.append(CompletionCandidate(value: cleanName, description: sanitizeField(label, limit: 72)))
                }
            }
        }

        return result
    }

    public static func keyCandidates() -> [CompletionCandidate] {
        [
            CompletionCandidate(value: "lcmd", description: "double-tap Left Command"),
            CompletionCandidate(value: "rcmd", description: "double-tap Right Command"),
            CompletionCandidate(value: "lopt", description: "double-tap Left Option"),
            CompletionCandidate(value: "ropt", description: "double-tap Right Option"),
            CompletionCandidate(value: "lctrl", description: "double-tap Left Control"),
            CompletionCandidate(value: "rctrl", description: "double-tap Right Control"),
            CompletionCandidate(value: "lshift", description: "double-tap Left Shift"),
            CompletionCandidate(value: "rshift", description: "double-tap Right Shift"),
            CompletionCandidate(value: "fn", description: "double-tap Fn / Globe"),
            CompletionCandidate(value: "capsLock", description: "double-tap Caps Lock (auto-remapped to F18)"),
            CompletionCandidate(value: "cmd", description: "double-tap either Command"),
            CompletionCandidate(value: "opt", description: "double-tap either Option"),
            CompletionCandidate(value: "ctrl", description: "double-tap either Control"),
            CompletionCandidate(value: "shift", description: "double-tap either Shift"),
            CompletionCandidate(value: "fn+space", description: "example key combo"),
            CompletionCandidate(value: "fn+escape", description: "example key combo"),
            CompletionCandidate(value: "capsLock+space", description: "example Caps Lock combo"),
            CompletionCandidate(value: "fn:q", description: "example two-step sequence (fn > q)")
        ]
    }

    public static func formatCandidates(_ candidates: [CompletionCandidate], plain: Bool) -> String {
        var lines: [String] = []
        lines.reserveCapacity(candidates.count)
        for candidate in candidates {
            let value = sanitizeField(candidate.value, limit: 120)
            guard !value.isEmpty else { continue }
            if plain {
                lines.append(value)
            } else {
                let desc = sanitizeField(candidate.description, limit: 80)
                lines.append("\(value)\t\(desc)")
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func sanitizeField(_ raw: String, limit: Int) -> String {
        StrictModes.sanitizeTerminalText(raw, limit: limit)
    }

    private static func primaryCommandPreview(for shortcut: Shortcut) -> String {
        if let tap = shortcut.tap, let doubleTap = shortcut.doubleTap {
            return "tap: \(tap) | 2x: \(doubleTap)"
        }
        return shortcut.tap ?? shortcut.doubleTap ?? ""
    }

    // MARK: - Install path resolution

    public static func defaultInstallURL(for shell: CompletionShell) -> URL {
        if Paths.isEnvironmentOverrideActive {
            let dir = Paths.root.appendingPathComponent("completions", isDirectory: true)
            switch shell {
            case .zsh:
                return dir.appendingPathComponent("zsh/_hotkeyd")
            case .bash:
                return dir.appendingPathComponent("bash/hotkeyd")
            case .fish:
                return dir.appendingPathComponent("fish/hotkeyd.fish")
            }
        }
        let home = Paths.realHomeDirectory
        switch shell {
        case .zsh:
            return home.appendingPathComponent(".local/share/zsh/site-functions/_hotkeyd")
        case .bash:
            return home.appendingPathComponent(".local/share/bash-completion/completions/hotkeyd")
        case .fish:
            return home.appendingPathComponent(".config/fish/completions/hotkeyd.fish")
        }
    }

    public static func activationHint(for shell: CompletionShell, installURL: URL) -> String {
        switch shell {
        case .zsh:
            let dir = installURL.deletingLastPathComponent().path
            return "Ensure `fpath=(\"\(dir)\" $fpath)` precedes `autoload -Uz compinit && compinit` in ~/.zshrc, then start a new shell."
        case .bash:
            return "Source `\(installURL.path)` in ~/.bashrc (or enable bash-completion v2, which auto-loads ~/.local/share/bash-completion/completions)."
        case .fish:
            return "Fish auto-loads ~/.config/fish/completions/hotkeyd.fish in new shells (no config edits required)."
        }
    }

    // MARK: - Script generation

    public static func generateScript(for shell: CompletionShell, version: String) -> String {
        switch shell {
        case .zsh:
            return generateZsh(version: version)
        case .bash:
            return generateBash(version: version)
        case .fish:
            return generateFish(version: version)
        }
    }

    // MARK: - Shared registry inspection

    private struct TopLevelEntry {
        let name: String
        let summary: String
    }

    private static func topLevelEntries() -> [TopLevelEntry] {
        var entries: [TopLevelEntry] = []
        var seen: Set<String> = []

        for spec in CommandRegistry.commands {
            guard let head = spec.path.first else { continue }
            if spec.path.count == 1 {
                if seen.insert(head).inserted {
                    entries.append(TopLevelEntry(name: head, summary: spec.summary))
                }
                for alias in spec.aliases where !alias.hasPrefix("-") {
                    if seen.insert(alias).inserted {
                        entries.append(TopLevelEntry(name: alias, summary: "Alias for \(head)"))
                    }
                }
            } else if seen.insert(head).inserted {
                let groupSummary: String
                switch head {
                case "daemon":
                    groupSummary = "Manage the background LaunchAgent daemon"
                case "caps":
                    groupSummary = "Inspect or toggle Caps Lock to F18 remapping"
                case "peek":
                    groupSummary = "Preview or fuzzy-search shortcuts in a peek HUD or terminal"
                default:
                    groupSummary = "\(head) subcommands"
                }
                entries.append(TopLevelEntry(name: head, summary: groupSummary))
            }
        }

        if seen.insert("help").inserted {
            entries.append(TopLevelEntry(name: "help", summary: "Show usage or detailed help for a command"))
        }
        return entries
    }

    private static func groupNames() -> [String] {
        var groups: [String] = []
        var seen: Set<String> = []
        for spec in CommandRegistry.commands where spec.path.count > 1 {
            if let head = spec.path.first, seen.insert(head).inserted {
                groups.append(head)
            }
        }
        return groups
    }

    private static func canonicalCommandNamesForHelp() -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for spec in CommandRegistry.commands {
            if let first = spec.path.first, seen.insert(first).inserted {
                names.append(first)
            }
        }
        return names
    }

    private static func positionalKind(for spec: CommandSpec) -> String? {
        guard let firstArg = spec.args.first else { return nil }
        switch spec.path {
        case ["enable"]:
            return "shortcuts-disabled"
        case ["disable"]:
            return "shortcuts-enabled"
        case ["show"], ["remove"], ["set"], ["run"]:
            return "shortcuts-all"
        case ["add"]:
            return "keys"
        case ["schema"]:
            return "schema-target"
        case ["completions"]:
            return "shell"
        default:
            if firstArg.name.contains("keys|name") {
                return "shortcuts-all"
            }
            return nil
        }
    }

    private static func flagValueHint(for flag: FlagSpec) -> String {
        switch flag.name {
        case "--starter":
            return "enum:minimal empty skip"
        case "--since":
            return "enum:all 24h 7d 30d"
        case "--for":
            return "enum:5m 15m 30m 1h 2h"
        case "--delay":
            return "enum:300 450 600 800 1000"
        case "--triggers":
            return "enum:fn fn,capsLock capsLock lcmd none"
        case "--cwd":
            return "dir"
        case "--binary":
            return "file"
        case "--keys", "--toggle", "--search-toggle":
            return "keys"
        default:
            return "none"
        }
    }

    // MARK: - Zsh generator

    private static func generateZsh(version: String) -> String {
        var out: [String] = []
        out.append("#compdef hotkeyd")
        out.append("# Generated by hotkeyd \(version) — do not edit by hand.")
        out.append("# Regenerate via: hotkeyd completions zsh")
        out.append("")
        out.append("_hotkeyd_shortcuts() {")
        out.append("  local filter_flag=\"$1\"")
        out.append("  local -a entries")
        out.append("  local line val desc escaped_val")
        out.append("  local -a cmd=(command hotkeyd __complete shortcuts)")
        out.append("  [[ -n \"$filter_flag\" ]] && cmd+=(\"$filter_flag\")")
        out.append("  while IFS=$'\\t' read -r val desc; do")
        out.append("    [[ -z \"$val\" ]] && continue")
        out.append("    escaped_val=${val//\\\\/\\\\\\\\}")
        out.append("    escaped_val=${escaped_val//:/\\\\:}")
        out.append("    entries+=(\"${escaped_val}:${desc}\")")
        out.append("  done < <(\"${cmd[@]}\" 2>/dev/null)")
        out.append("  (( ${#entries[@]} > 0 )) && _describe -t shortcuts 'shortcut' entries")
        out.append("}")
        out.append("")
        out.append("_hotkeyd_keys() {")
        out.append("  local -a entries")
        out.append("  local val desc escaped_val")
        out.append("  while IFS=$'\\t' read -r val desc; do")
        out.append("    [[ -z \"$val\" ]] && continue")
        out.append("    escaped_val=${val//\\\\/\\\\\\\\}")
        out.append("    escaped_val=${escaped_val//:/\\\\:}")
        out.append("    entries+=(\"${escaped_val}:${desc}\")")
        out.append("  done < <(command hotkeyd __complete keys 2>/dev/null)")
        out.append("  (( ${#entries[@]} > 0 )) && _describe -t keys 'key target' entries")
        out.append("}")
        out.append("")

        // Group helpers
        for group in groupNames() {
            let subs = CommandRegistry.findGroupCommands(group: group)
            let defaultFlagSub: CommandSpec? = (group == "peek")
                ? subs.first(where: { $0.path.last == "toggle" })
                : nil
            out.append("_hotkeyd_group_\(group)() {")
            out.append("  local -a subcommands=(")
            for sub in subs {
                guard let name = sub.path.last else { continue }
                out.append("    \(zshSingleQuote("\(name):\(sanitizeField(sub.summary, limit: 76))"))")
            }
            out.append("  )")
            if let defaultSub = defaultFlagSub {
                out.append("  if [[ \"${words[2]}\" == -* ]]; then")
                out.append(contentsOf: zshArgumentsBlock(for: defaultSub, indent: "    "))
                out.append("    return")
                out.append("  fi")
            }
            out.append("  if (( CURRENT == 2 )); then")
            out.append("    _describe -t subcommands '\(group) subcommand' subcommands")
            out.append("    return")
            out.append("  fi")
            out.append("  local subcmd=\"${words[2]}\"")
            out.append("  shift words")
            out.append("  (( CURRENT-- ))")
            out.append("  case \"$subcmd\" in")
            for sub in subs {
                guard let name = sub.path.last else { continue }
                out.append("    \(name))")
                out.append(contentsOf: zshArgumentsBlock(for: sub, indent: "      "))
                out.append("      ;;")
            }
            out.append("  esac")
            out.append("}")
            out.append("")
        }

        out.append("_hotkeyd() {")
        out.append("  local -a commands=(")
        for entry in topLevelEntries() {
            out.append("    \(zshSingleQuote("\(entry.name):\(sanitizeField(entry.summary, limit: 76))"))")
        }
        out.append("  )")
        out.append("")
        out.append("  if (( CURRENT == 2 )); then")
        out.append("    _describe -t commands 'hotkeyd command' commands")
        out.append("    return")
        out.append("  fi")
        out.append("")
        out.append("  local cmd=\"${words[2]}\"")
        out.append("  shift words")
        out.append("  (( CURRENT-- ))")
        out.append("")
        out.append("  case \"$cmd\" in")

        for group in groupNames() {
            out.append("    \(group))")
            out.append("      _hotkeyd_group_\(group)")
            out.append("      ;;")
        }

        for spec in CommandRegistry.commands where spec.path.count == 1 {
            guard let name = spec.path.first else { continue }
            let patterns = ([name] + spec.aliases.filter { !$0.hasPrefix("-") }).joined(separator: "|")
            out.append("    \(patterns))")
            out.append(contentsOf: zshArgumentsBlock(for: spec, indent: "      "))
            out.append("      ;;")
        }

        let helpTargets = canonicalCommandNamesForHelp().joined(separator: " ")
        out.append("    help)")
        out.append("      if (( CURRENT == 2 )); then")
        out.append("        local -a help_cmds=(\(helpTargets))")
        out.append("        _describe -t commands 'command' help_cmds")
        out.append("      elif (( CURRENT == 3 )); then")
        out.append("        case \"${words[2]}\" in")
        for group in groupNames() {
            let subNames = CommandRegistry.findGroupCommands(group: group).compactMap(\.path.last).joined(separator: " ")
            out.append("          \(group)) local -a subs=(\(subNames)); _describe -t subcommands 'subcommand' subs ;;")
        }
        out.append("        esac")
        out.append("      fi")
        out.append("      ;;")
        out.append("  esac")
        out.append("}")
        out.append("")
        out.append("if [ \"$funcstack[1]\" = \"_hotkeyd\" ]; then")
        out.append("  _hotkeyd \"$@\"")
        out.append("else")
        out.append("  compdef _hotkeyd hotkeyd")
        out.append("fi")
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func zshArgumentsBlock(for spec: CommandSpec, indent: String) -> [String] {
        var lines: [String] = []
        lines.append("\(indent)_arguments -S \\")
        for flag in spec.flags {
            let desc = zshEscapeSpecDescription(sanitizeField(flag.description, limit: 76))
            let specString: String
            if flag.isBooleanSwitch {
                specString = "\(flag.name)[\(desc)]"
            } else {
                let valueAction: String
                switch flagValueHint(for: flag) {
                case "enum:minimal empty skip":
                    valueAction = ":(minimal empty skip)"
                case "enum:all 24h 7d 30d":
                    valueAction = ":(all 24h 7d 30d)"
                case "enum:5m 15m 30m 1h 2h":
                    valueAction = ":(5m 15m 30m 1h 2h)"
                case "enum:300 450 600 800 1000":
                    valueAction = ":(300 450 600 800 1000)"
                case "enum:fn fn,capsLock capsLock lcmd none":
                    valueAction = ":(fn fn,capsLock capsLock lcmd none)"
                case "dir":
                    valueAction = ":directory:_directories"
                case "file":
                    valueAction = ":file:_files"
                case "keys":
                    valueAction = ":keys:_hotkeyd_keys"
                default:
                    valueAction = ":\(sanitizeField(flag.type, limit: 24)):"
                }
                specString = "\(flag.name)[\(desc)]\(valueAction)"
            }
            lines.append("\(indent)  \(zshSingleQuote(specString)) \\")
        }

        if let posKind = positionalKind(for: spec) {
            let argSpec: String
            switch posKind {
            case "shortcuts-all":
                argSpec = "1:shortcut:_hotkeyd_shortcuts"
            case "shortcuts-enabled":
                argSpec = "1:enabled shortcut:{_hotkeyd_shortcuts --enabled}"
            case "shortcuts-disabled":
                argSpec = "1:disabled shortcut:{_hotkeyd_shortcuts --disabled}"
            case "keys":
                argSpec = "1:key target:_hotkeyd_keys"
            case "schema-target":
                argSpec = "1:target:(config shortcut)"
            case "shell":
                argSpec = "1:shell:(zsh bash fish)"
            default:
                argSpec = "1:arg:"
            }
            lines.append("\(indent)  \(zshSingleQuote(argSpec))")
        } else {
            // Trim trailing backslash from last flag line if no positional argument exists.
            if let last = lines.popLast() {
                if last.hasSuffix(" \\") {
                    lines.append(String(last.dropLast(2)))
                } else {
                    lines.append(last)
                }
            }
        }
        return lines
    }

    private static func zshSingleQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func zshEscapeSpecDescription(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: ":", with: "\\:")
    }

    // MARK: - Bash generator

    private static func generateBash(version: String) -> String {
        var out: [String] = []
        let topNames = topLevelEntries().map(\.name).joined(separator: " ")

        out.append("# Generated by hotkeyd \(version) — do not edit by hand.")
        out.append("# Regenerate via: hotkeyd completions bash")
        out.append("")
        out.append("_hotkeyd_complete_dynamic() {")
        out.append("  local kind=\"$1\"")
        out.append("  local filter_flag=\"$2\"")
        out.append("  local cur=\"$3\"")
        out.append("  local item quoted")
        out.append("  local -a cmd=(command hotkeyd __complete \"$kind\" --plain)")
        out.append("  [[ -n \"$filter_flag\" ]] && cmd+=(\"$filter_flag\")")
        out.append("  while IFS= read -r item; do")
        out.append("    [[ -z \"$item\" ]] && continue")
        out.append("    printf -v quoted '%q' \"$item\"")
        out.append("    if [[ \"$item\" == \"$cur\"* || \"$quoted\" == \"$cur\"* ]]; then")
        out.append("      COMPREPLY+=(\"$quoted\")")
        out.append("    fi")
        out.append("  done < <(\"${cmd[@]}\" 2>/dev/null)")
        out.append("}")
        out.append("")
        out.append("_hotkeyd_complete_paths() {")
        out.append("  local flag=\"$1\"")
        out.append("  local cur=\"$2\"")
        out.append("  local item quoted")
        out.append("  while IFS= read -r item; do")
        out.append("    [[ -z \"$item\" ]] && continue")
        out.append("    printf -v quoted '%q' \"$item\"")
        out.append("    COMPREPLY+=(\"$quoted\")")
        out.append("  done < <(compgen \"$flag\" -- \"$cur\")")
        out.append("}")
        out.append("")
        out.append("_hotkeyd_completions() {")
        out.append("  local cur prev cmd subcmd")
        out.append("  COMPREPLY=()")
        out.append("  cur=\"${COMP_WORDS[COMP_CWORD]}\"")
        out.append("  prev=\"${COMP_WORDS[COMP_CWORD-1]}\"")
        out.append("")
        out.append("  if [[ $COMP_CWORD -eq 1 ]]; then")
        out.append("    COMPREPLY=( $(compgen -W \"\(topNames)\" -- \"$cur\") )")
        out.append("    return 0")
        out.append("  fi")
        out.append("")
        out.append("  cmd=\"${COMP_WORDS[1]}\"")
        out.append("")
        out.append("  case \"$prev\" in")
        out.append("    --starter)")
        out.append("      COMPREPLY=( $(compgen -W \"minimal empty skip\" -- \"$cur\") )")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --since)")
        out.append("      COMPREPLY=( $(compgen -W \"all 24h 7d 30d\" -- \"$cur\") )")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --for)")
        out.append("      COMPREPLY=( $(compgen -W \"5m 15m 30m 1h 2h\" -- \"$cur\") )")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --delay)")
        out.append("      COMPREPLY=( $(compgen -W \"300 450 600 800 1000\" -- \"$cur\") )")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --triggers)")
        out.append("      COMPREPLY=( $(compgen -W \"fn fn,capsLock capsLock lcmd none\" -- \"$cur\") )")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --toggle|--search-toggle)")
        out.append("      if [[ \"$cmd\" == \"peek\" ]]; then")
        out.append("        _hotkeyd_complete_dynamic keys \"\" \"$cur\"")
        out.append("        return 0")
        out.append("      fi")
        out.append("      ;;")
        out.append("    --cwd)")
        out.append("      _hotkeyd_complete_paths -d \"$cur\"")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --binary)")
        out.append("      _hotkeyd_complete_paths -f \"$cur\"")
        out.append("      return 0")
        out.append("      ;;")
        out.append("    --keys)")
        out.append("      _hotkeyd_complete_dynamic keys \"\" \"$cur\"")
        out.append("      return 0")
        out.append("      ;;")
        out.append("  esac")
        out.append("")
        out.append("  case \"$cmd\" in")

        for group in groupNames() {
            let subs = CommandRegistry.findGroupCommands(group: group)
            let subList = subs.compactMap(\.path.last).joined(separator: " ")
            let defaultFlags: String? = (group == "peek")
                ? subs.first(where: { $0.path.last == "toggle" })?.flags.map(\.name).joined(separator: " ")
                : nil
            out.append("    \(group))")
            out.append("      if [[ $COMP_CWORD -eq 2 ]]; then")
            if let defaultFlags {
                out.append("        if [[ \"$cur\" == -* ]]; then")
                out.append("          COMPREPLY=( $(compgen -W \"\(defaultFlags)\" -- \"$cur\") )")
                out.append("        else")
                out.append("          COMPREPLY=( $(compgen -W \"\(subList)\" -- \"$cur\") )")
                out.append("        fi")
            } else {
                out.append("        COMPREPLY=( $(compgen -W \"\(subList)\" -- \"$cur\") )")
            }
            out.append("        return 0")
            out.append("      fi")
            out.append("      subcmd=\"${COMP_WORDS[2]}\"")
            if let defaultFlags {
                out.append("      if [[ \"$subcmd\" == -* ]]; then")
                out.append("        if [[ \"$cur\" == -* ]]; then")
                out.append("          COMPREPLY=( $(compgen -W \"\(defaultFlags)\" -- \"$cur\") )")
                out.append("        fi")
                out.append("        return 0")
                out.append("      fi")
            }
            out.append("      case \"$subcmd\" in")
            for sub in subs {
                guard let subName = sub.path.last else { continue }
                let flags = sub.flags.map(\.name).joined(separator: " ")
                out.append("        \(subName))")
                out.append("          if [[ \"$cur\" == -* ]]; then")
                out.append("            COMPREPLY=( $(compgen -W \"\(flags)\" -- \"$cur\") )")
                out.append("          fi")
                out.append("          ;;")
            }
            out.append("      esac")
            out.append("      return 0")
            out.append("      ;;")
        }

        for spec in CommandRegistry.commands where spec.path.count == 1 {
            guard let name = spec.path.first else { continue }
            let patterns = ([name] + spec.aliases.filter { !$0.hasPrefix("-") }).joined(separator: "|")
            let flags = spec.flags.map(\.name).joined(separator: " ")
            out.append("    \(patterns))")
            out.append("      if [[ \"$cur\" == -* ]]; then")
            out.append("        COMPREPLY=( $(compgen -W \"\(flags)\" -- \"$cur\") )")
            out.append("        return 0")
            out.append("      fi")
            if let posKind = positionalKind(for: spec) {
                switch posKind {
                case "shortcuts-all":
                    out.append("      _hotkeyd_complete_dynamic shortcuts \"\" \"$cur\"")
                case "shortcuts-enabled":
                    out.append("      _hotkeyd_complete_dynamic shortcuts \"--enabled\" \"$cur\"")
                case "shortcuts-disabled":
                    out.append("      _hotkeyd_complete_dynamic shortcuts \"--disabled\" \"$cur\"")
                case "keys":
                    out.append("      _hotkeyd_complete_dynamic keys \"\" \"$cur\"")
                case "schema-target":
                    out.append("      COMPREPLY=( $(compgen -W \"config shortcut\" -- \"$cur\") )")
                case "shell":
                    out.append("      COMPREPLY=( $(compgen -W \"zsh bash fish\" -- \"$cur\") )")
                default:
                    break
                }
            }
            out.append("      return 0")
            out.append("      ;;")
        }

        let helpTargets = canonicalCommandNamesForHelp().joined(separator: " ")
        out.append("    help)")
        out.append("      if [[ $COMP_CWORD -eq 2 ]]; then")
        out.append("        COMPREPLY=( $(compgen -W \"\(helpTargets)\" -- \"$cur\") )")
        out.append("      elif [[ $COMP_CWORD -eq 3 ]]; then")
        out.append("        case \"${COMP_WORDS[2]}\" in")
        for group in groupNames() {
            let subList = CommandRegistry.findGroupCommands(group: group).compactMap(\.path.last).joined(separator: " ")
            out.append("          \(group)) COMPREPLY=( $(compgen -W \"\(subList)\" -- \"$cur\") ) ;;")
        }
        out.append("        esac")
        out.append("      fi")
        out.append("      return 0")
        out.append("      ;;")
        out.append("  esac")
        out.append("}")
        out.append("")
        out.append("complete -F _hotkeyd_completions hotkeyd")
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: - Fish generator

    private static func generateFish(version: String) -> String {
        var out: [String] = []
        out.append("# Generated by hotkeyd \(version) — do not edit by hand.")
        out.append("# Regenerate via: hotkeyd completions fish")
        out.append("")
        out.append("complete -c hotkeyd -e")
        out.append("complete -c hotkeyd -f")
        out.append("")
        out.append("# Top-level commands")
        for entry in topLevelEntries() {
            out.append(
                "complete -c hotkeyd -n '__fish_use_subcommand' -a \(fishSingleQuote(entry.name)) -d \(fishSingleQuote(sanitizeField(entry.summary, limit: 76)))"
            )
        }
        out.append("")

        for group in groupNames() {
            let subs = CommandRegistry.findGroupCommands(group: group)
            let subNames = subs.compactMap(\.path.last).joined(separator: " ")
            out.append("# \(group) subcommands")
            for sub in subs {
                guard let subName = sub.path.last else { continue }
                let cond = "__fish_seen_subcommand_from \(group); and not __fish_seen_subcommand_from \(subNames)"
                out.append(
                    "complete -c hotkeyd -n \(fishSingleQuote(cond)) -a \(fishSingleQuote(subName)) -d \(fishSingleQuote(sanitizeField(sub.summary, limit: 76)))"
                )
                let flagCond: String
                if group == "peek" && subName == "toggle" {
                    let otherSubs = subs.compactMap(\.path.last).filter { $0 != "toggle" }.joined(separator: " ")
                    flagCond = "__fish_seen_subcommand_from peek; and not __fish_seen_subcommand_from \(otherSubs)"
                } else {
                    flagCond = "__fish_seen_subcommand_from \(group); and __fish_seen_subcommand_from \(subName)"
                }
                out.append(contentsOf: fishFlagLines(for: sub, condition: flagCond))
            }
            out.append("")
        }

        out.append("# Single-level command flags and dynamic arguments")
        for spec in CommandRegistry.commands where spec.path.count == 1 {
            guard let name = spec.path.first else { continue }
            let matchNames = ([name] + spec.aliases.filter { !$0.hasPrefix("-") }).joined(separator: " ")
            let cond = "__fish_seen_subcommand_from \(matchNames)"
            out.append(contentsOf: fishFlagLines(for: spec, condition: cond))

            if let posKind = positionalKind(for: spec) {
                switch posKind {
                case "shortcuts-all":
                    out.append("complete -c hotkeyd -n \(fishSingleQuote(cond)) -a '(command hotkeyd __complete shortcuts 2>/dev/null)'")
                case "shortcuts-enabled":
                    out.append("complete -c hotkeyd -n \(fishSingleQuote(cond)) -a '(command hotkeyd __complete shortcuts --enabled 2>/dev/null)'")
                case "shortcuts-disabled":
                    out.append("complete -c hotkeyd -n \(fishSingleQuote(cond)) -a '(command hotkeyd __complete shortcuts --disabled 2>/dev/null)'")
                case "keys":
                    out.append("complete -c hotkeyd -n \(fishSingleQuote(cond)) -a '(command hotkeyd __complete keys 2>/dev/null)'")
                case "schema-target":
                    out.append("complete -c hotkeyd -n \(fishSingleQuote(cond)) -a 'config shortcut'")
                case "shell":
                    out.append("complete -c hotkeyd -n \(fishSingleQuote(cond)) -a 'zsh bash fish'")
                default:
                    break
                }
            }
        }

        let helpTargets = canonicalCommandNamesForHelp().joined(separator: " ")
        out.append("complete -c hotkeyd -n '__fish_seen_subcommand_from help' -a \(fishSingleQuote(helpTargets))")
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func fishFlagLines(for spec: CommandSpec, condition: String) -> [String] {
        var lines: [String] = []
        for flag in spec.flags {
            let longName = flag.bareName
            let desc = fishSingleQuote(sanitizeField(flag.description, limit: 76))
            if flag.isBooleanSwitch {
                lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -d \(desc)")
            } else {
                switch flagValueHint(for: flag) {
                case "enum:minimal empty skip":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a 'minimal empty skip' -d \(desc)")
                case "enum:all 24h 7d 30d":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a 'all 24h 7d 30d' -d \(desc)")
                case "enum:5m 15m 30m 1h 2h":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a '5m 15m 30m 1h 2h' -d \(desc)")
                case "enum:300 450 600 800 1000":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a '300 450 600 800 1000' -d \(desc)")
                case "enum:fn fn,capsLock capsLock lcmd none":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a 'fn fn,capsLock capsLock lcmd none' -d \(desc)")
                case "dir":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a '(__fish_complete_directories)' -d \(desc)")
                case "file":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -F -d \(desc)")
                case "keys":
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -a '(command hotkeyd __complete keys 2>/dev/null)' -d \(desc)")
                default:
                    lines.append("complete -c hotkeyd -n \(fishSingleQuote(condition)) -l \(longName) -r -d \(desc)")
                }
            }
        }
        return lines
    }

    private static func fishSingleQuote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
