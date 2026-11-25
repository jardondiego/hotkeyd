# hotkeyd

Global keyboard shortcuts for macOS, from the command line. Headless pure-Swift daemon — no Dock icon, no menu bar — with an opt-in hold-`fn` cheatsheet overlay and Spotlight search HUD.

[Install](#install) · [Features](#features) · [Compare](#how-hotkeyd-compares) · [Commands](#commands) · [Config](#config) · [Security](#signing--security) · [Troubleshooting](#troubleshooting--uninstall)

---

### Four triggers, one schema

- **Key combos** — `cmd+shift+c`, `ctrl+alt+k`, `f13`, `fn+space`, `capsLock+space`
- **Two-step sequences** — tap a modifier leader, then press a key (`fn > q`, `rcmd > space`, `capsLock > a`; shell-safe `fn:q`)
- **Double-tapped modifiers** — ⌘, ⌥, ⌃, ⇧, `fn` (`globe`), or **Caps Lock**
- **Double-tapped key combos** — hold `fn`, tap `esc` twice

```bash
hotkeyd add cmd+shift+c 'open -a "Google Chrome"'
hotkeyd add fn:q 'open -a Safari'
hotkeyd add capsLock 'open -a "Visual Studio Code"'
hotkeyd add lcmd 'open -a Terminal'
hotkeyd add opt 'open https://github.com'
hotkeyd add fn+escape --tap 'osascript -e "set volume output muted true"' \
                       --double-tap 'osascript -e "set volume output volume 100"'
hotkeyd init
hotkeyd doctor
```

- **Fast native launches:** `open -a <App>`, `open <https://...>`, and `open <~/dir>` run directly via `NSWorkspace` (zero shell spawn, never blocked by slow scripts).
- **Safe shell actions:** Arbitrary commands run in `/bin/zsh -fc` (`NO_RCS`) with a scrubbed environment and disclaimed Accessibility TCC by default (`--allow-accessibility` opts in).
- **Clipboard-free selection:** Commands referencing `SELECTED_TEXT` receive highlighted text (and `SELECTED_TEXT_STATUS`: `ok`, `empty`, `secure`, `disabled`, `untrusted`) via Accessibility without touching your clipboard.

---

## Install

Requires **macOS 14.5+** and Apple Command Line Tools 16+ (Swift 6, tested on Apple Silicon) — no Xcode needed.

### Recommended (keeps Accessibility across rebuilds)

```bash
git clone https://github.com/jardondiego/hotkeyd.git
cd hotkeyd
./scripts/setup-signing.sh
./scripts/build.sh
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.zshrc to persist
hotkeyd init
```

- `setup-signing.sh` creates a dedicated `0600` local signing keychain (`~/Library/Keychains/hotkeyd-signing.keychain-db`, auto-locked).
- `build.sh` compiles a release binary, signs it with Hardened Runtime (`CS_RUNTIME`) and a leaf-anchored requirement, and installs `~/.local/bin/hotkeyd` + `man hotkeyd`.
- `hotkeyd init` walks through first-time setup in under a minute (trust check, optional 3 starter shortcuts, LaunchAgent install, live Accessibility check, and trigger verification).

### Quick try (skip local signing keychain)

```bash
./scripts/build.sh --adhoc
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.zshrc to persist
hotkeyd init --allow-adhoc
```

> [!NOTE]
> Local certificate signing (`setup-signing.sh`) is recommended for daily use — without it, macOS resets Accessibility permission whenever you rebuild or upgrade, and `SELECTED_TEXT` / `--allow-accessibility` stay disabled. Switch anytime with `./scripts/setup-signing.sh && ./scripts/build.sh --install`.

**Post-install tips:** Install dynamic shell completions with `hotkeyd completions zsh --install` (also supports `bash` and `fish`), read `man hotkeyd`, or run `hotkeyd doctor` anytime to diagnose issues. If you skip editing `PATH`, run `~/.local/bin/hotkeyd` directly.

---

## Features

### Triggers & Gestures

- **Override existing app shortcuts:** A session-level `CGEventTap` intercepts key events before the focused app sees them (e.g. `⌘⇧C` overrides Chrome's Inspect Element unless `--pass-through` is set).
- **Release-based modifier double-taps:** Fires on the second *release*, not press — so a fast `cmd, cmd+k` never triggers accidentally, and releasing a prior letter during fast typing never drops tap 1.
- **Paired tap & double-tap combos:** Hold modifiers, tap the key once or twice. Single taps flush immediately on modifier release; double-tap-only combos (e.g. `fn+e`) swallow tap 1 cleanly.
- **Two-step sequences (`fn > q` / `fn:q`):** A clean bare modifier tap (`<= 250 ms`) arms a short-lived leader (`maxSequenceDelayMs`: `250 ms` default, `100..1500 ms`). Unbound step-2 keys pass through immediately; Apple Silicon Globe (`179`) events after `fn` are ignored; unsided `shift` is forbidden as a leader (use `lshift` / `rshift`).
- **Left & right modifier precision:** `lcmd`/`rcmd`, `lopt`/`ropt`, `lctrl`/`rctrl`, `lshift`/`rshift` target one side; `cmd`/`opt`/`ctrl`/`shift` match either (exact side wins over family fallback). Modifier events are never swallowed, so keys can never get stuck.

### Caps Lock as a Real Key

- **HID-level remap to F18:** Remaps Caps Lock below the event tap so it works as a double-tap, sequence leader (`capsLock > a`), or chord modifier (`capsLock+space`).
- **Self-healing lifecycle:** Automatically re-applies across sleep/wake and external keyboard hotplug, swallows raw F18 during Secure Input, and removes the remap on stop/uninstall so a dead daemon never costs you Caps Lock.
- **Authoritative LED state:** Reads and writes true lock state via `IOHIDGet/SetModifierLockState` (`hotkeyd caps status` / `reset` / `off`), forces Caps off before remapping, and runs an automatic stuck-caps watchdog.

### Peek Cheatsheet & Spotlight Search (`hotkeyd peek`)

Opt in with `hotkeyd peek enable`, then:

- **Hold `fn` (`450 ms` default):** Opens a zero-focus-steal monochrome cheatsheet grouped by trigger family with side-aware keycaps (`L⌘`, `R⌘`, `fn`, `⇪`). Release `fn` to hide, press a key to run it immediately, or tap `Tab` to pin hands-free.
- **Live modifier spotlighting:** While pinned (or opened via `hotkeyd peek` / `--toggle`), holding *any* modifier highlights its related shortcuts in place with zero layout jump.
- **Spotlight fuzzy search:** Press `/` (or run `hotkeyd peek --search` / bind `--search-toggle`) to search shortcuts ranked by `actions.log` frequency — `Enter` runs, `Esc` closes, `⌘C` copies keys, `⌘⇧C` copies the command.
- **Isolated helper subprocess:** Rendered inside a lazy, strictly one-way TCC-disclaimed helper that exits on idle so the daemon stays 100% headless (`[AX]`, `[SEL]`, and `[off]` bindings stay muted and prompt to press their key directly).

### Built for AI Agents & Automation

- **Structured JSON everywhere:** Consistent `--json` envelopes with explicit boolean DTOs (`enabled`, `passThrough`, `allowAccessibility`, `executionMode`, `usesSelectedText`) and round-tripping canonical keys (`doubleTap:cmd`).
- **Self-describing & safe to automate:** `hotkeyd describe --json` exports the full CLI manifest, `hotkeyd schema` emits JSON Schema (draft 2020-12), `--dry-run` previews mutations, `run --wait` executes and inspects results without a keyboard, and `doctor` reports deterministic exit codes.

### How hotkeyd compares

| Tool | Model | Caps Lock Gesture | Two-Step Sequences | Modifier Double-Tap | Peek / Search HUD | Agent JSON & Schema | Security Boundary |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **hotkeyd** | Pure-Swift CLI + LaunchAgent | Built-in (`hidutil` + IOKit + auto-restore) | Built-in (`fn > q`) | Built-in (2nd release, L/R-aware) | Opt-in Bento + Spotlight HUD | Full (`--json`, `describe`, Schema) | Hardened Runtime, leaf cert, TCC disclaim, `0600` `StrictModes` |
| **skhd** | C daemon + rc file | External (`hidutil`/Karabiner) | Modes | No | No | No | Standard user process |
| **Karabiner-Elements** | DriverKit virtual HID remapper | Full remap & layers | Complex JSON rules | Complex JSON rules | No | No | DriverKit virtual device |
| **Hammerspoon** | Lua automation platform | Via Lua/external | Lua modal hotkeys | Lua eventtap | Custom Lua canvas | No | Full Lua runtime |
| **Raycast** | GUI launcher & extensions | External (Hyper key) | No | Alias/extension | GUI launcher | No | GUI app |

Use **hotkeyd** for a fast, single-file, version-controlled CLI hotkey daemon with L/R modifier double-taps, two-step sequences, safe `SELECTED_TEXT` scripts, and an optional cheatsheet/search HUD — without a GUI app or Lua runtime. Use **Karabiner-Elements** for low-level key remapping/layers, or **Hammerspoon** for full Lua window management.

---

## Commands

### Everyday commands

| Command | Purpose |
| :--- | :--- |
| `hotkeyd init` | Interactive first-time setup (trust check, starter bindings, LaunchAgent, verification) |
| `hotkeyd add <keys> <cmd>` | Add a shortcut (`--tap`, `--double-tap`, `--name`, `--allow-accessibility`, `--dry-run`) |
| `hotkeyd set <keys\|name> ...` | Update command or metadata (`--name`, `--timeout`, `--clear-*`) |
| `hotkeyd list` / `show` / `remove` | Inspect or delete bindings (`--full`, `--tap`, `--double-tap`) |
| `hotkeyd enable` / `disable` | Temporarily toggle a shortcut without deleting it |
| `hotkeyd edit` / `validate` | Edit `~/.hotkeyd` in `$EDITOR` with pre-save validation & rollover overlap checks |
| `hotkeyd run <keys\|name>` | Trigger a shortcut from the CLI (`--wait` to capture exit code & output) |
| `hotkeyd peek [enable\|--search]` | Open/configure the hold-`fn` cheatsheet and Spotlight fuzzy search HUD |
| `hotkeyd pause` / `resume` / `panic` | Pause shortcuts (`--for 10m`), re-arm, or emergency-stop daemon & restore Caps Lock |
| `hotkeyd status` / `logs` / `stats` / `doctor` | Inspect daemon state, tail logs (`-f`), view usage rankings, or run health diagnostics |

<details>
<summary><strong>Full CLI reference & flags</strong></summary>

```
hotkeyd init [--starter <minimal|empty|skip>] [--no-daemon] [--no-open]
             [--no-verify] [--allow-adhoc] [--dry-run] [--non-interactive] [--json]
hotkeyd completions <zsh|bash|fish> [--install] [--json]
hotkeyd man [--install] [--json]                        # generate or install `man hotkeyd`

hotkeyd add <keys> [command] [--tap <cmd>] [--double-tap <cmd>] [--force] [--dry-run]
             [--name <name>] [--max-double-tap-delay <100..600 ms>]
             [--max-sequence-delay <100..1500 ms>] [--timeout <ms>] [--cwd <dir>]
             [--pass-through | --no-pass-through]
             [--allow-accessibility | --no-allow-accessibility] [--json]
hotkeyd set <keys|name> [command] [same options as add, or metadata-only updates +
             --clear-name | --clear-cwd | --clear-timeout | --clear-delays]
hotkeyd list (ls) [--full] [--json]
hotkeyd show <keys|name> [--json]
hotkeyd remove (rm) <keys|name> [--tap | --double-tap] [--dry-run] [--json]
hotkeyd enable <keys|name> [--dry-run] [--json]
hotkeyd disable <keys|name> [--dry-run] [--json]
hotkeyd validate [--json]
hotkeyd edit                                            # safe $EDITOR with pre-save validation
hotkeyd run <keys|name> [--tap | --double-tap] [--wait] [--json]
hotkeyd migrate-actions [--dry-run] [--json]

hotkeyd daemon status [--json]
hotkeyd daemon start [--json]
hotkeyd daemon stop [--json]
hotkeyd daemon reload [--json]                          # SIGHUP live daemon to reload ~/.hotkeyd
hotkeyd daemon restart [--json]
hotkeyd daemon logs [--lines <n>] [--daemon] [--actions] [--follow|-f] [--utc] [--json]
hotkeyd daemon install [--binary <path>] [--allow-adhoc] [--no-open] [--json]
hotkeyd daemon uninstall [--json]
hotkeyd daemon run [--allow-adhoc]                      # foreground, used by launchd
hotkeyd pause [--for <duration>] [--reason <text>] [--toggle] [--json]
hotkeyd resume [--json]                                 # re-arm shortcuts after pause
hotkeyd panic [--json]                                  # stop daemon & restore Caps Lock immediately

hotkeyd caps [status|on|off|reset] [--json]

hotkeyd peek [--search] [--terminal] [--query <text>] [--show-disabled] [--json]
                                                        # toggle cheatsheet/search HUD or print CLI
hotkeyd peek status [--json]                            # inspect hold triggers, delay & toggle keys
hotkeyd peek enable | disable [--dry-run] [--json]
hotkeyd peek set [--triggers <list>] [--delay <ms>] [--toggle <keys>|--clear-toggle]
                 [--search-toggle <keys>|--clear-search-toggle] [--dim|--no-dim]
                 [--show-disabled|--hide-disabled] [--reset] [--dry-run] [--json]

hotkeyd status [--json]
hotkeyd logs [--lines <n>] [--daemon] [--actions] [--follow|-f] [--utc] [--json]
hotkeyd stats [--since <7d|30d|24h|all>] [--top <n>] [--unused] [--json]
hotkeyd doctor [--json]
hotkeyd describe [--json]
hotkeyd schema [config|shortcut] [--json]
hotkeyd help [command] [--json]
hotkeyd version [--json]
```

</details>

**Exit codes:** `0` ok · `2` usage · `3` not found · `4` conflict/validation · `5` permission · `6` daemon · `7` config IO/signing · `8` action failed.

### Examples

```bash
# App & URL launches (native NSWorkspace, zero shell spawn)
hotkeyd add cmd 'open -a Terminal'
hotkeyd add opt 'open https://github.com'
hotkeyd add cmd+shift+c 'open -a "Google Chrome"'

# Two-step sequences (quoted 'fn > q' or shell-safe fn:q)
hotkeyd add fn:q 'open -a Safari'
hotkeyd add rcmd:f1 'open ~/Projects' --max-sequence-delay 400

# Pair single-tap and double-tap on the same chord
hotkeyd add fn+escape \
  --tap 'osascript -e "set volume output muted true"' \
  --double-tap 'osascript -e "set volume output volume 100" -e "set volume output muted false"'

# Metadata updates, inspection & toggling
hotkeyd set fn+space --name 'Screenshot' --timeout 60000
hotkeyd show Screenshot
hotkeyd disable Screenshot && hotkeyd enable Screenshot
hotkeyd validate

# Highlighted-text search (no clipboard touch, no --allow-accessibility needed)
hotkeyd add fn+c 'q="${SELECTED_TEXT:-$(pbpaste)}"; [ -n "$q" ] && open "https://www.google.com/search?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote_plus(sys.argv[1]))" "$q")"'

# Opt a trusted script into inheriting Accessibility TCC attribution
hotkeyd add fn 'yabai -m window --display next' --allow-accessibility
```

### Agent / scripting usage

```bash
hotkeyd describe --json                   # full manifest of commands, flags, keys & exit codes
hotkeyd schema                            # JSON Schema (draft 2020-12) for ~/.hotkeyd
hotkeyd set cmd 'open -a Terminal' --json
hotkeyd list --json | jq '.data.shortcuts[] | select(.enabled == true) | .keys'
hotkeyd show lcmd --json
hotkeyd run cmd --wait --json             # {ok, data: {name, command, detached, exitCode, timedOut, ...}}
hotkeyd doctor --json | jq '.data.checks[] | select(.ok == false)'
```

Set `HOTKEYD_HOME` to sandbox experiments without touching your live `~/.hotkeyd` or LaunchAgent.

---

## Config

Bindings live in **`~/.hotkeyd`** (plain JSON, one line per shortcut, written atomically with mode `0600`). Logs and `runtime-state.json` live in `~/Library/Application Support/Hotkeyd/`.

```json
{
  "shortcuts": [
    { "keys": "fn+space", "tap": "open -a Notes", "name": "Notes" },
    { "keys": "fn > q", "tap": "open -a Safari", "name": "Safari", "maxSequenceDelayMs": 450 },
    { "keys": "lcmd", "doubleTap": "open -a \"Google Chrome\"", "name": "Chrome" },
    { "keys": "capsLock", "doubleTap": "open -a \"Visual Studio Code\"", "name": "VS Code" },
    { "keys": "fn+escape", "tap": "osascript -e 'set volume output muted true'", "doubleTap": "osascript -e 'set volume output volume 100'", "name": "Volume" }
  ]
}
```

- **Live reload:** The daemon watches `~/.hotkeyd` (125 ms debounce) and reloads automatically on change.
- **Dotfiles:** Restore with `install -m 0600 path/to/.hotkeyd ~/.hotkeyd` (symlinks and `0644` permissions are rejected by `StrictModes`), or edit safely via `hotkeyd edit`.
- **Reserved system shortcuts:** Refused rather than stolen — `⌘Q`, `⌃⌘Q` (Lock Screen), `⌘⇧Q` / `⌘⇧⌥Q` (Log Out), `⌘⌥Esc` (Force Quit), `⌘Tab`, `` ⌘` ``, unsided `⌘Space` (`lcmd+space`/`rcmd+space` allowed), `⌃F1`–`F3`, bare `shift` on non-function keys, and `shift > <key>`.

### Timing defaults

| Constant | Default | Configurable Range / Meaning |
| :--- | :--- | :--- |
| Tap max | `250 ms` | Longer than this is a hold, not a tap |
| Modifier double-tap delay | `400 ms` | `maxDoubleTapDelayMs` (`100–600 ms`) between release 1 and press 2 |
| Combo double-tap delay | `250 ms` | `maxDoubleTapDelayMs` (`100–600 ms`) for paired key combos |
| Max sequence delay | `250 ms` | `maxSequenceDelayMs` (`100–1500 ms`) between step 1 release and step 2 press |
| Peek hold delay | `450 ms` | `peek.delayMs` (`300–2000 ms`) before showing the opt-in cheatsheet |
| Cooldown | `400 ms` | Ensures a triple-tap fires once |

---

## How it works

- **Headless LaunchAgent:** `hotkeyd daemon run` owns the `CGEventTap` under `launchd`; the CLI never touches the event tap, so Accessibility belongs to a stable code identity rather than your terminal.
- **Stateless config:** Bindings live on disk in `0600` `~/.hotkeyd`, never only in daemon memory.

### Signing & Security

`setup-signing.sh` creates a dedicated `0600` keychain (`~/Library/Keychains/hotkeyd-signing.keychain-db`, auto-locked after 300s) with the `Hotkeyd Local Signing` certificate, and `build.sh` signs with Hardened Runtime (`--options runtime`) plus a leaf-anchored designated requirement:

```
designated => identifier "io.github.jardondiego.hotkeyd" and certificate leaf = H"<40-hex-sha1>"
```

At startup and install, `CodeTrust` and `StrictModes` enforce:

- **Path hygiene:** Every component from `/` to the binary and config dir is owned by `getuid()` or `root`, symlink-free, traversal-free, and not group/world-writable.
- **Binary & live-process trust:** Validates both on-disk (`kSecCSStrictValidate | kSecCSCheckAllArchitectures`) and live in-memory (`SecCodeCopySelf`) signatures, `CS_RUNTIME`, zero relaxation or `com.apple.private.*` entitlements, and the compiled leaf anchor (unless `--allow-adhoc`).
- **Config & password-field safety:** Opens `~/.hotkeyd` via `openat(O_NOFOLLOW | O_NONBLOCK)` + `fstat` (`0600`, `<= 1 MiB`), and pauses all triggers whenever `IsSecureEventInputEnabled()` is active (still swallowing remapped Caps Lock F18).
- **TCC isolation:** Child `/bin/zsh -fc` processes disclaim Accessibility responsibility (`responsibility_spawnattrs_setdisclaim`) by default (and unconditionally under `HOTKEYD_HOME` or `--allow-adhoc`) with a scrubbed `PATH`.

See [docs/security-model.md](docs/security-model.md) for the full threat model and trust boundaries, and [SECURITY.md](SECURITY.md) for vulnerability reporting.

---

## Troubleshooting & Uninstall

```bash
hotkeyd doctor     # checks trust, permissions, LaunchAgent & Caps Lock
hotkeyd status     # live runtime-state.json (daemon, tap, Secure Input)
hotkeyd validate   # checks ~/.hotkeyd syntax & rollover overlaps
hotkeyd logs -f    # tail live daemon & action logs
```

- **Tap inactive:** Enable `hotkeyd` in **System Settings → Privacy & Security → Accessibility** (click `+` and select `~/.local/bin/hotkeyd` if missing). Moving the binary requires re-adding it.
- **Nothing fires:** Run `hotkeyd status` to verify the daemon is running, the tap is active, and Secure Event Input isn't pausing triggers.
- **Secure Input:** Password fields pause shortcuts automatically (while still swallowing remapped F18); gestures resume once focus leaves the field.
- **Caps Lock stuck or foreign mapping:** Check `hotkeyd caps status`, run `hotkeyd caps reset` for stuck caps state, or `hotkeyd caps off` to restore without the daemon. Hotkeyd refuses to overwrite foreign HID mappings (e.g. Karabiner-Elements) and reports them in `doctor`.
- **Forgot signing keychain password:** Delete `~/Library/Keychains/hotkeyd-signing.keychain-db`, re-run `./scripts/setup-signing.sh && ./scripts/build.sh`, and re-toggle `hotkeyd` once in Accessibility.
- **Complete uninstall:** Run `hotkeyd daemon uninstall`, delete `~/.local/bin/hotkeyd`, `~/Library/Application Support/Hotkeyd/`, `~/Library/Keychains/hotkeyd-signing.keychain-db`, and `~/.hotkeyd`, then remove `hotkeyd` from Accessibility settings.

---

## Limitations & Non-Goals

- **Global shortcuts only (for now):** Per-app or window-title scoping is not implemented yet.
- **Not a low-level key remapper:** Triggers actions rather than building keyboard layers (use Karabiner-Elements for full remapping).
- **Caps Lock coexistence:** Remaps Caps Lock → F18 via `hidutil` when a `capsLock` binding exists and refuses to overwrite foreign mappings.
- **Source build only (for now):** No prebuilt Developer ID notarized binary or Homebrew Cask yet — builds locally with Apple Command Line Tools 16+ (Swift 6).
- **Headless by design:** No menu bar icon, Dock icon, GUI settings window, or mouse-button triggers.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

---

## Development

```bash
./scripts/check.sh                   # full gate: bash -n, git diff --check, selftest, release build
./scripts/test.sh                    # full selftest suite (no XCTest required)
./scripts/test.sh --filter init      # targeted suite (--list to view all)
./scripts/build.sh                   # build + sign + install binary & man page (restarts daemon)
./scripts/build.sh --install
./scripts/build.sh --adhoc --install # skip local cert keychain (resets Accessibility on rebuild)
swift run hotkeyd-dev listen         # uninstalled interactive event-tap inspector (TTY only)
```

100% pure Swift, zero external dependencies, zero C targets:

```
Sources/HotkeydCore/   core logic: detectors, key combos, IOKit caps, RuntimeState, PauseState,
                       PeekConfig/Model/Search, StatsAnalyzer, SelectionReader, StrictModes,
                       CodeTrust, Config, CommandRegistry, InitSupport, ShellCompletions,
                       ManPageGenerator, and Darwin posix_spawn ShellRunner
Sources/hotkeyd/       production CLI, onboarding, completions/man, stats, pause/resume,
                       peek overlay & CLI, daemon, LaunchAgent
Sources/hotkeyd-dev/   uninstalled developer event-tap inspector (listen, tap, modtap)
Sources/selftest/      dependency-free executable test suite
```

## License

MIT — see [LICENSE](LICENSE).
