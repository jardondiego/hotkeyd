# hotkeyd

Global keyboard shortcuts for macOS, from the command line. Headless daemon, no Dock icon, no menu bar — plus an opt-in hold-`fn` quick-reference overlay and Spotlight search HUD.

Four trigger types, one unified schema (`keys` + `tap` and/or `doubleTap`):

- **key combos** — `cmd+shift+c`, `ctrl+alt+k`, `f13`, `fn+space`, `capsLock+space`
- **two-step sequences** — tap a modifier leader, then press a key (`fn > q`, `rcmd > space`, `capsLock > a`; or shell-safe `fn:q`)
- **double-tapped modifiers** — ⌘, ⌥, ⌃, ⇧, `fn` (`globe`), or **Caps Lock**
- **double-tapped key combos** — hold `fn`, tap `esc` twice

Simple `open -a <App>`, `open <https://...>`, and `open <~/dir>` commands run natively via `NSWorkspace` without spawning a shell (and bypass the shell worker pool so slow scripts never starve app switching). Arbitrary shell commands run `/bin/zsh -fc <command>` (`NO_RCS`) with a scrubbed environment and disclaim the daemon's Accessibility TCC responsibility by default (`--allow-accessibility` opts in). Commands whose string contains `SELECTED_TEXT` automatically receive `SELECTED_TEXT` and `SELECTED_TEXT_STATUS` (`ok`, `empty`, `secure`, `disabled`, `untrusted`) via macOS Accessibility without touching the clipboard or needing `--allow-accessibility`.

```bash
hotkeyd add cmd+shift+c 'open -a "Google Chrome"'
hotkeyd add fn:q 'open -a Safari'
hotkeyd add capsLock 'open -a "Visual Studio Code"'
hotkeyd add lcmd 'open -a Terminal'
hotkeyd add opt 'open https://github.com'
hotkeyd add fn+escape --tap 'osascript -e "set volume output muted true"' \
                       --double-tap 'osascript -e "set volume output volume 100"'
hotkeyd daemon install
hotkeyd doctor
```

## Why this is not "just another hotkey app"

**It can take keys apps already use.** A session-level `CGEventTap` sees key events before the
focused app does, so a binding can override an existing shortcut instead of only adding a free
one. (⌘⇧c, for example, is Chrome's "inspect element" until hotkeyd swallows it.)

**Caps Lock becomes a real gesture key.** macOS toggles Caps Lock below the event tap, so it is
remapped to F18 at the HID level; the tap can then see, swallow, double-tap, or hold it as a chord modifier (`capsLock+space`). The daemon automatically re-applies the remap across sleep/wake and external keyboard hotplug, swallows raw F18 during Secure Input, and removes the remap when stopped so a dead daemon never costs you a Caps Lock key.

Caps **state** is separate from the key, and it lives in IOHIDSystem — `CGEventSource.flagsState`
is not authoritative and can report "off" while the keyboard types uppercase. hotkeyd reads and
sets the state through `IOHIDGet/SetModifierLockState`, so `hotkeyd caps status` shows the truth.

If caps is on when the remap is applied, the key can no longer toggle it off. Enabling the remap
therefore forces the state off first and refuses to proceed if it cannot; while remapped, a
coalesced watchdog clears any stuck caps-on state automatically. `hotkeyd caps reset` is the manual
equivalent, and `hotkeyd caps off` restores the key and stands the watchdog down.

**Modifier double-taps are detected on the second *release*, not the second press.** If it fired
on the second press, a fast `cmd, cmd+k` would launch an app instead of doing what you asked.
Firing on release means the second press must be a complete, clean tap, and any `keyDown`, mouse event,
or extra modifier in between cancels it (while releasing a prior typed letter during fast typing rollover never drops tap 1).

**Double-tapped key combos** work the other way around: hold the modifiers, tap the key twice.
A single tap waits out the combo double-tap window (250 ms default) before firing, so a double-tap runs only the
double action. Releasing the modifier early flushes the single action immediately. Double-tap-only combos (like `fn+e`) swallow tap 1 so macOS does not trigger a stray shortcut before tap 2.

**Two-step sequences (`<modifier> > <key>`)** let a clean bare modifier tap (`<= 250 ms`) act as a short-lived leader before a regular key press (default `maxSequenceDelayMs`: `250 ms`, configurable `100..1500 ms`). On the CLI, you can pass either quoted `'fn > q'` or shell-safe `fn:q` (both canonicalize to `fn > q`). Unbound step-2 keys pass straight through and disarm immediately, firing a bare-modifier `doubleTap` disarms any active leader, synthetic Apple Silicon Globe (`179`) events after `fn` are ignored, and unsided `shift` is forbidden as a sequence leader (use `lshift` or `rshift`).

**Modifier events are never swallowed.** A gesture consumes nothing, so it can never drop a ⌘
or leave a key stuck. The detector only observes.

**Left and right modifiers are distinct.** `lcmd`, `rcmd`, `lopt`, `ropt`, `lctrl`, `rctrl`,
`lshift`, `rshift` address one side; `cmd`, `opt`, `ctrl`, `shift` match either side. If both a
side-specific and a side-agnostic binding exist, the exact side wins and the family-level one is
the fallback for the other side.

**Zero-focus-steal peek cheatsheet & Spotlight search (`hotkeyd peek`).** Opt in with `hotkeyd peek enable`, then hold `fn` (450 ms default) to glance at all your shortcuts auto-grouped by trigger family with side-aware keycaps (`L⌘`, `R⌘`, `fn`, `⇪`); release `fn` to hide, press a binding's key to run it immediately, or tap `Tab` to pin the overlay open hands-free. Once pinned (or opened via `hotkeyd peek` / `hotkeyd peek set --toggle fn:/`), holding *any* modifier spotlights its related shortcuts in place with zero layout jump, and pressing `/` (or `hotkeyd peek --search` / `hotkeyd peek set --search-toggle fn:s`) opens a Spotlight-style fuzzy search launcher ranked by `actions.log` usage frequency (`Enter` runs, `Esc` closes immediately, `⌘C` copies keys, `⌘⇧C` copies the raw command). Rendered inside a lazy, strictly one-way TCC-disclaimed helper subprocess (`[AX]`, `[SEL]`, and `[off]` shortcuts show muted tags and prompt to press their key directly) that exits on idle so the daemon stays 100% headless.

**It is built to be driven by agents.** Structured JSON envelopes (`--json`) across commands,
explicit boolean DTOs (`enabled`, `passThrough`, `allowAccessibility`, `executionMode`, `usesSelectedText`),
canonical `doubleTap:cmd` display strings that round-trip, `--dry-run` previews, `run --wait`
to execute and inspect a shell action without a keyboard, and `doctor` with authoritative
`runtime-state.json` health checks and deterministic non-zero exit codes.

### How hotkeyd compares

| Tool | Model | Caps Lock Gesture | Two-Step Sequences | Modifier Double-Tap | Peek / Search HUD | Agent JSON & Schema | Security Boundary |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **hotkeyd** | Pure-Swift headless CLI + LaunchAgent | Built-in (`hidutil` + IOKit LED + auto-restore) | Built-in (`fn > q`) | Built-in (2nd release, L/R-aware) | Opt-in monochrome Bento + Spotlight HUD | Full (`--json`, `describe`, JSON Schema) | Hardened Runtime, leaf-pinned cert, TCC disclaim, `0600` `StrictModes` |
| **skhd** | Lightweight C daemon + rc file | External (`hidutil`/Karabiner) | Modes | No | No | No | Standard user process |
| **Karabiner-Elements** | Kernel/DriverKit virtual HID remapper | Full low-level remap & layers | Via complex JSON rules | Via complex JSON rules | No | No | DriverKit virtual device |
| **Hammerspoon** | Lua automation platform | Via Lua/external | Via Lua modal hotkeys | Via Lua eventtap | Custom Lua canvas | No | Full Lua runtime |
| **Raycast** | Full GUI launcher & extension suite | External (Hyper key) | No | Alias/extension | GUI launcher | No | GUI app |

Use **hotkeyd** if you want a fast, single-file, version-controlled CLI hotkey daemon with left/right modifier double-taps, two-step sequences, safe `SELECTED_TEXT` scripts, and an optional cheatsheet/search HUD without running a GUI app or Lua runtime. Use **Karabiner-Elements** if you need low-level keyboard layers/remapping, or **Hammerspoon** if you want full Lua window-management scripting.

## Requirements

- macOS 14.5 or newer (Swift 6 / Command Line Tools 16+; tested on Apple Silicon)
- Command Line Tools only — no Xcode needed

## Install

```bash
git clone https://github.com/jardondiego/hotkeyd.git
cd hotkeyd
./scripts/setup-signing.sh
./scripts/build.sh
export PATH="$HOME/.local/bin:$PATH"   # add this line to ~/.zshrc to persist
hotkeyd init
```

`setup-signing.sh` creates a dedicated local signing keychain (`~/Library/Keychains/hotkeyd-signing.keychain-db`, `0600`, auto-locked). `build.sh` compiles from source, asks to unlock that keychain once to sign with Hardened Runtime (`CS_RUNTIME`) and a leaf-anchored Designated Requirement, installs `~/.local/bin/hotkeyd`, and installs the `hotkeyd(1)` manual page (`~/.local/share/man/man1/hotkeyd.1`). If you prefer not to edit `PATH`, invoke `~/.local/bin/hotkeyd init` directly.

`hotkeyd init` guides first-time setup in under a minute: validates binary trust and `~/.hotkeyd`, optionally creates 3 auto-detected starter shortcuts (default browser, active terminal, Home folder), installs the LaunchAgent with live Accessibility polling, and runs a safe live trigger verification. You can also install dynamic shell completions (`hotkeyd completions zsh --install`) and read `man hotkeyd`.

`hotkeyd doctor` tells you exactly what is missing and how to fix it.

## Commands

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

Exit codes: `0` ok · `2` usage · `3` not found · `4` conflict/validation · `5` permission ·
`6` daemon · `7` config IO/signing · `8` action failed.

### Examples

```bash
# Launch (or focus) an app on modifier double-tap (runs natively via NSWorkspace)
hotkeyd add cmd 'open -a Terminal'

# Open a URL on modifier double-tap (runs natively via NSWorkspace)
hotkeyd add opt 'open https://github.com'

# Single-tap key combo
hotkeyd add cmd+shift+c 'open -a "Google Chrome"'

# Two-step modifier > key sequence (quoted 'fn > q' or shell-safe fn:q)
hotkeyd add fn:q 'open -a Safari'
hotkeyd add rcmd:f1 'open ~/Projects' --max-sequence-delay 400

# Pair single-tap and double-tap on the same key chord (fn+escape)
hotkeyd add fn+escape \
  --tap 'osascript -e "set volume output muted true"' \
  --double-tap 'osascript -e "set volume output volume 100" -e "set volume output muted false"'

# Update metadata on an existing shortcut without re-passing its command
hotkeyd set fn+space --name 'Screenshot' --timeout 60000

# Inspect a shortcut in full, or disable/re-enable it temporarily
hotkeyd show Screenshot
hotkeyd disable Screenshot
hotkeyd enable Screenshot

# Validate config & check for mod+key vs mod > key rollover overlaps
hotkeyd validate

# Operate on highlighted text without touching the clipboard or granting --allow-accessibility
hotkeyd add fn+c 'q="${SELECTED_TEXT:-$(pbpaste)}"; [ -n "$q" ] && open "https://www.google.com/search?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote_plus(sys.argv[1]))" "$q")"'

# Explicitly opt a trusted accessibility script into inheriting TCC attribution
hotkeyd add fn 'yabai -m window --display next' --allow-accessibility
```

### Agents

```bash
hotkeyd describe --json                   # full manifest of commands, flags, keys & exit codes
hotkeyd schema                            # JSON Schema (draft 2020-12) for ~/.hotkeyd
hotkeyd set cmd 'open -a Terminal' --json
hotkeyd list --json | jq '.data.shortcuts[] | select(.enabled == true) | .keys'
hotkeyd show lcmd --json
hotkeyd run cmd --wait --json             # {ok, data: {name, command, detached, exitCode, timedOut, ...}}
hotkeyd doctor --json | jq '.data.checks[] | select(.ok == false)'
```

The config lives at **`~/.hotkeyd`** — easy to find, diff and version. Logs and `runtime-state.json` stay in
`~/Library/Application Support/Hotkeyd/`. Set `HOTKEYD_HOME` to sandbox an experiment
without touching real bindings.

## Config

`~/.hotkeyd`, written atomically (one line per shortcut), mode `0600`:

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

Reserved combinations are refused rather than silently stolen: ⌘q, ⌃⌘q (Lock Screen), ⌘⇧q / ⌘⇧⌥q (Log Out), ⌘⌥esc (Force Quit), ⌘tab, ⌘`, ⌘space (unsided only; `lcmd+space` / `rcmd+space` are allowed because the other side keeps Spotlight), ⌃f1–f3, `shift` alone on non-function keys, and `shift > <key>` (unsided `shift` sequence leader). A key combo or sequence step-2 key is swallowed (it never reaches the app) unless `passThrough` is set.

The daemon watches `~/.hotkeyd` (debounced 125 ms) and reloads on change. When restoring from a dotfiles repo, use `install -m 0600 path/to/.hotkeyd ~/.hotkeyd` (never symlink or leave `0644`, which `StrictModes` refuses) or edit safely via `hotkeyd edit`.

### Timing

| Constant | Default | Meaning |
|---|---|---|
| tap max | 250 ms | longer than this is a hold, not a tap |
| modifier double-tap delay | 400 ms | max gap between first release and second press (`maxDoubleTapDelayMs`, 100–600) |
| combo double-tap delay | 250 ms | default double-tap window for paired key combos (`maxDoubleTapDelayMs`, 100–600) |
| max sequence delay | 250 ms | max gap between releasing step 1 and pressing step 2 (`maxSequenceDelayMs`, 100–1500) |
| peek hold delay | 450 ms | sustained modifier hold before showing the opt-in shortcut reference overlay (`peek.delayMs`, 300–2000) |
| cooldown | 400 ms | a triple-tap fires once |

## How it works

- `hotkeyd daemon run` is a headless LaunchAgent. It owns the `CGEventTap`; the CLI never
  touches it.
- The daemon runs under launchd, so the Accessibility grant belongs to a stable code identity
  at a stable path rather than to your terminal.
- Bindings live in a plain `0600` JSON file (`~/.hotkeyd`), not in daemon memory, so deploying
  from dotfiles with `install -m 0600` (or `hotkeyd edit`) reloads atomically.

### Signing & Security

`setup-signing.sh` creates a dedicated local signing keychain (`~/Library/Keychains/hotkeyd-signing.keychain-db`, mode `0600`, auto-locked after 300s) containing the `Hotkeyd Local Signing` certificate. `build.sh` signs the binary with Hardened Runtime (`--options runtime`) and a leaf-anchored designated requirement:

```
designated => identifier "io.github.jardondiego.hotkeyd" and certificate leaf = H"<40-hex-sha1>"
```

This keeps the Accessibility grant across rebuilds while preventing another local binary from spoofing `io.github.jardondiego.hotkeyd`. At startup (`hotkeyd daemon run`) and install (`hotkeyd daemon install`), `CodeTrust` and `StrictModes` verify:

- Every path component from `/` to the binary and config directory is owned by `getuid()` or `root`, free of symlinks and `.` / `..` traversal components, and not group/world-writable.
- Both the on-disk binary (`kSecCSStrictValidate | kSecCSCheckAllArchitectures`) and the live in-memory Mach task (`SecCodeCopySelf`) carry valid signatures, `CS_RUNTIME` (Hardened Runtime), zero relaxation or private entitlements (`get-task-allow`, `allow-dyld-environment-variables`, `disable-library-validation`, `allow-unsigned-executable-memory`, `disable-executable-page-protection`, `allow-jit`, `debugger`, `com.apple.private.*`), and a compiled leaf-certificate requirement (unless `--allow-adhoc` is explicitly passed).
- `~/.hotkeyd` is opened via `openat` on a verified directory descriptor with `O_NOFOLLOW | O_NONBLOCK` and checked via `fstat` (`S_ISREG`, `st_uid == getuid()`, mode `0600`, `<= 1 MiB`), and the daemon goes inert whenever `IsSecureEventInputEnabled()` is active (still swallowing remapped Caps Lock F18 so password fields never receive raw F18).
- Child `/bin/zsh -fc` processes disclaim TCC responsibility via `responsibility_spawnattrs_setdisclaim` by default (and unconditionally under `HOTKEYD_HOME` or `--allow-adhoc`) and run in a scrubbed environment with root-owned system `PATH` entries ahead of Homebrew.

## Troubleshooting & Uninstall

```bash
hotkeyd doctor
hotkeyd status
hotkeyd validate
hotkeyd logs -f
```

- **Tap inactive** — enable `hotkeyd` in Accessibility. If the entry is missing, use `+` and
  choose `~/.local/bin/hotkeyd`. If you moved the binary, re-add it: TCC remembers paths.
- **Nothing fires** — `hotkeyd status` reads live `runtime-state.json` and shows whether the daemon
  is running, whether the tap is active, and whether Secure Event Input is currently pausing shortcuts.
- **Secure Input** — while a password field has Secure Input active, macOS pauses shortcuts
  (and hotkeyd swallows remapped F18 so Caps Lock never leaks raw keys). Gestures resume when the field loses focus.
- **Caps Lock** — `hotkeyd caps status` shows whether the F18 remap is active. `hotkeyd caps
  off` restores it without needing the daemon, and `hotkeyd caps reset` clears a stuck caps
  state. If another tool owns a HID key mapping, hotkeyd refuses to overwrite it and says so in
  `doctor`.
- **Forgot signing keychain password** — delete `~/Library/Keychains/hotkeyd-signing.keychain-db`,
  re-run `./scripts/setup-signing.sh` and `./scripts/build.sh`, then re-toggle `hotkeyd` once in
  System Settings → Privacy & Security → Accessibility.
- **Complete uninstall** — run `hotkeyd daemon uninstall`, remove `~/.local/bin/hotkeyd`,
  `~/Library/Application Support/Hotkeyd/`, `~/Library/Keychains/hotkeyd-signing.keychain-db`,
  and `~/.hotkeyd`, then remove `hotkeyd` from System Settings → Privacy & Security → Accessibility.

## Limitations & Non-Goals

- **Global shortcuts only (for now):** Per-app or window-title scoping is not implemented yet.
- **Not a low-level key remapper:** Hotkeyd triggers actions; it does not build keyboard layers or remap arbitrary keys (use Karabiner-Elements for that).
- **Caps Lock coexistence:** When you add a `capsLock` binding, Hotkeyd remaps Caps Lock → F18 via `hidutil` and refuses to overwrite foreign mappings (such as Karabiner-Elements' Caps Lock rules).
- **Source build only for now:** No prebuilt Developer ID notarized binary or Homebrew Cask yet — installation builds locally with Apple Command Line Tools 16+ (Swift 6).
- **Headless by design:** No menu bar icon, Dock icon, GUI settings window, or mouse-button triggers.

See [SECURITY.md](SECURITY.md) for vulnerability reporting and [CHANGELOG.md](CHANGELOG.md) for release notes.

## Development

```bash
./scripts/check.sh                   # full gate: bash -n, git diff --check, selftest, release build
./scripts/test.sh                    # full selftest suite, no XCTest required
./scripts/test.sh --filter init      # fast targeted run of one test suite (--list to see all)
./scripts/build.sh                   # build + sign + install binary & man page (restarts daemon)
./scripts/build.sh --install
swift run hotkeyd-dev listen         # uninstalled interactive event-tap inspector (TTY only)
```

Layout (100% pure Swift, zero external dependencies, zero C targets):

```
Sources/HotkeydCore/      pure, testable logic: double-tap & sequence detectors, key combos,
                           IOKit caps state/remap, RuntimeState, PauseState, PeekConfig,
                           PeekModel, PeekSearch, StatsAnalyzer, SelectionReader, StrictModes,
                           CodeTrust, Config, CommandRegistry, InitSupport, ShellCompletions,
                           ManPageGenerator, and Darwin posix_spawn shell runner
Sources/hotkeyd/          production CLI, onboarding, completions/man, stats, pause/resume,
                           peek overlay & CLI, daemon, LaunchAgent
Sources/hotkeyd-dev/      uninstalled developer event-tap inspector (listen, tap, modtap)
Sources/selftest/         dependency-free executable test suite
```

## License

MIT — see [LICENSE](LICENSE).
