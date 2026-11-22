---
name: hotkeyd
description: Safely inspect, create, update, validate, test, and diagnose global macOS keyboard shortcuts, modifier double-taps, and two-step sequences using the hotkeyd CLI. Use whenever the user asks to bind, change, remove, list, debug, or verify macOS shortcuts managed by hotkeyd or ~/.hotkeyd.
---

# Operating Hotkeyd

Hotkeyd manages global macOS shortcuts via a single mode-0600 JSON file (`~/.hotkeyd`) watched by a signed background LaunchAgent daemon. Always drive changes through the `hotkeyd` CLI with `--json` rather than editing `~/.hotkeyd` with raw shell commands.

## 1. Discover the Live Contract First

When unsure of exact flags, key tokens, reserved combos, or exit codes, query the binary directly:

```bash
hotkeyd describe --json
hotkeyd schema
hotkeyd list --json
hotkeyd doctor --json
```

Canonical exit codes: `0` ok, `2` usage, `3` not found, `4` conflict/validation, `5` permission/Accessibility, `6` daemon/launchctl, `7` config I/O or signing, `8` action failed/timed out.

## 2. Inspect Before Mutating

1. Run `hotkeyd list --json` first to see existing `keys`, `name`, `enabled`, and `executionMode` values so you avoid trigger collisions or duplicate names.
2. For experiments or automated dry tests, isolate with `HOTKEYD_HOME="$(mktemp -d)"` (mode `0700`) so the user's live `~/.hotkeyd` and daemon are untouched.
3. Preview mutations with `--dry-run --json` before applying when modifying complex or high-impact bindings.

## 3. Trigger & Action Best Practices

- **Choose the right trigger type:**
  - Bare modifier double-tap: `lcmd`, `rcmd`, `lopt`, `ropt`, `lctrl`, `rctrl`, `lshift`, `rshift`, `fn`, `capsLock` (uses `--double-tap` or positional shorthand).
  - Key combo: `fn+space`, `capsLock+space`, `cmd+shift+c`, `fn+escape` (supports `--tap`, `--double-tap`, or both paired on one entry).
  - Two-step sequence: `'fn > q'` or shell-safe `fn:q` (tap modifier leader, release, press key; unsided `shift` is forbidden as a leader).
- **Prefer native NSWorkspace fast-path commands** (zero shell overhead, ~25 ms, no Accessibility delegation):
  - Apps: `open -a "Google Chrome"`, `open -a iTerm`
  - URLs: `open https://example.com`
  - Plain directories: `open ~`, `open ~/Downloads`
- **Use `SELECTED_TEXT` for highlighted-text workflows:**
  - Any command containing `SELECTED_TEXT` automatically receives `SELECTED_TEXT` and `SELECTED_TEXT_STATUS` (`ok`, `empty`, `secure`, `disabled`, `untrusted`) directly from the daemon without touching the clipboard or needing `--allow-accessibility`.
- **Keep `--allow-accessibility` off by default:**
  - Only pass `--allow-accessibility` when the user explicitly needs a trusted script (e.g., `yabai` or UI-scripting `osascript`) to inherit the daemon's Accessibility permission.
- **Metadata updates in place:**
  - Use `hotkeyd set <keys|name> --name ... --timeout ... --cwd ...` to update metadata without rewriting the command.
  - Use `hotkeyd disable <keys|name>` / `hotkeyd enable <keys|name>` to toggle bindings cleanly.
- **Quick-reference peek overlay & Spotlight search (opt-in):**
  - Off by default; inspect with `hotkeyd peek status --json` and toggle via `hotkeyd peek enable` / `hotkeyd peek disable`. When enabled, hold `fn` for 450 ms to preview all shortcuts (`Tab` pins + hold any modifier to spotlight related keys; `/` opens Spotlight Search). Configure hotkeys via `hotkeyd peek set --toggle fn:/ --search-toggle fn:s` (clear with `--clear-toggle` / `--clear-search-toggle`), toggle live via `hotkeyd peek` / `hotkeyd peek --search`, or inspect offline via `hotkeyd peek --terminal --json` and `hotkeyd peek --search --terminal --query <text> --json`. Inside Search HUD, `Enter` runs normal shortcuts (`[AX]`, `[SEL]`, and `[off]` bindings prompt to press their key directly), `Esc` closes immediately, `⌘C` copies keys, and `⌘⇧C` copies the command.

## 4. Verify Changes End-to-End

After adding or editing shortcuts:

```bash
hotkeyd validate --json          # check schema + mod+key vs mod > key rollover overlaps
hotkeyd show <keys|name> --json  # verify canonical keys, flags, and executionMode
hotkeyd doctor --json            # verify config, daemon PID, event tap, Caps Lock, signing
```

To test a non-destructive action without pressing keys:

```bash
hotkeyd run <keys|name> --wait --json
```

(Never run destructive shortcuts like Lock Screen or Sleep Confirm with `hotkeyd run`.)

## 5. First-Time Setup & Troubleshooting

- **Headless bootstrap:** `hotkeyd init --non-interactive --starter minimal --json` (exits `5` with structured `data` + `nextSteps` if human Accessibility approval in System Settings is still pending; requires explicit `--starter` when `~/.hotkeyd` does not exist).
- **File permissions / symlinks:** `~/.hotkeyd` must be a regular user-owned `0600` file (`O_NOFOLLOW` rejects symlinks). If restoring from dotfiles, use `install -m 0600 path/to/.hotkeyd ~/.hotkeyd`.
- **Emergency stop:** `hotkeyd panic --json` stops the daemon and immediately restores Caps Lock if remapped.
- **Never run live `hotkeyd daemon stop|uninstall|restart|panic` without explicit user intent.**
