# Changelog

All notable changes to `hotkeyd` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-22

Initial public release of `hotkeyd` — a 100% pure-Swift, dependency-free macOS global keyboard shortcut daemon and CLI.

### Added
- **Four trigger types in one unified `0600` JSON schema (`~/.hotkeyd`):**
  - Key combinations (`fn+space`, `capsLock+space`, `cmd+shift+c`, bare `f1`–`f20`) with side-specific (`lcmd`/`rcmd`, `lopt`/`ropt`, `lctrl`/`rctrl`, `lshift`/`rshift`) and side-agnostic modifiers
  - Paired single-tap (`tap`) and double-tap (`doubleTap`) combos
  - Two-step modifier leader sequences (`fn > q` / `fn:q`, `capsLock > o`, `rcmd > space`)
  - Bare modifier double-taps firing cleanly on the second release (including Caps Lock remapped to F18 via `hidutil` + authoritative IOKit LED lock state, sleep/wake & keyboard hotplug recovery, and automatic restoration on stop/panic)
- **Fast, secure execution:**
  - Native `NSWorkspace` fast-path for `open -a <App>`, `open https://...`, and `open <dir>` (bypasses `/bin/zsh` and the 8-job shell worker pool)
  - `Darwin` `posix_spawn` shell runner (`/bin/zsh -fc`, `NO_RCS`, scrubbed env, dedicated process groups, PID-reuse-safe timeout termination)
  - `SELECTED_TEXT` extraction via macOS Accessibility without touching the clipboard or granting `--allow-accessibility` to child shells
- **Opt-in Peek Cheatsheet & Spotlight Search HUD (`hotkeyd peek`):**
  - Monochrome frosted-glass bento overlay (`fn` hold → `Tab` pin → hold any modifier to spotlight related keys in place with zero layout jump)
  - Unified Spotlight Search HUD (`/` while pinned, optional `peek.searchToggle`, `hotkeyd peek --search`, or offline `--search --terminal --query`) ranked by `actions.log` usage frequency with multi-token fuzzy matching, layout-independent shortcuts, Edit menu support, concealed local-only command copy (`⌘⇧C`), and direct non-AX/non-`SELECTED_TEXT` launch
- **CLI, onboarding & agent-first ergonomics:**
  - Guided `hotkeyd init`, full CRUD (`add`, `set`, `list`, `show`, `remove`, `enable`, `disable`, `validate`, `edit`, `run`, `migrate-actions`), `pause`/`resume`, `stats`, `logs`, `status`, `doctor`, `panic`
  - Structured `--json` envelopes, deterministic exit codes (`0`–`8`), `describe --json`, draft 2020-12 `schema`, dynamic `zsh`/`bash`/`fish` completions, and generated `man hotkeyd`
- **Hardened macOS security model:**
  - Hardened Runtime (`CS_RUNTIME`) + leaf-anchored designated requirement (`scripts/setup-signing.sh`, `scripts/build.sh`, `CodeTrust`)
  - OpenSSH-style `StrictModes` ancestor & `O_NOFOLLOW` `0600` file verification, `HOTKEYD_HOME` sandbox isolation, TCC responsibility disclaiming by default, Secure Event Input blackout (daemon + helper), comprehensive URI/shell secret redaction, and `DispatchSourceWrite` pipe framing + persistent child reaping
  - Self-contained pure-Swift regression suite (`./scripts/check.sh`, 1,840+ checks)
