# Hotkeyd — Agent Guide

Hotkeyd is a 100% pure-Swift, dependency-free headless global keyboard shortcut daemon and CLI for macOS (`macOS 14+`, Command Line Tools only). It uses a stateless `0600` file + `SIGHUP`/`SIGUSR1`/`SIGUSR2` architecture (no UDS socket, no Xcode; the daemon stays pure `dispatchMain()` headless and spawns an optional lazy, strictly one-way TCC-disclaimed AppKit helper subprocess over an unnamed pipe for the opt-in `hotkeyd peek` overlay and Spotlight search HUD).

> **Operating `hotkeyd` (managing shortcuts) rather than editing code?**
> Load [skills/hotkeyd/SKILL.md](skills/hotkeyd/SKILL.md) or run `hotkeyd describe --json`, `hotkeyd schema`, and `hotkeyd doctor --json` for the live machine contract. Always use `hotkeyd add|set|remove|edit` (never raw shell overwrites on `~/.hotkeyd`), and isolate experiments with `HOTKEYD_HOME=<temp_0700_dir>`.

---

## Repository Layout

| Target / Path | Role |
|---|---|
| `Sources/HotkeydCore/` | Pure, launchd/TCC-free library: `DoubleTapDetector`, `SequenceDetector`, `HeldModifiers`, `Modifier`, `KeyCombo`, `BindingIndex`, `CapsLock` (pure-Swift `IOKit` + `hidutil`), `Config`, `RuntimeState`, `PauseState`, `PeekConfig`, `PeekModel`, `PeekSearch`, `CommandRegistry`, `InitSupport`, `ShellCompletions`, `ManPageGenerator`, `StatsAnalyzer`, `Paths`, `StrictModes`, `CodeTrust`, `SelectionReader`, `ShellRunner` (`Darwin` `posix_spawn` + `NSWorkspace`), and `Log` |
| `Sources/hotkeyd/` | Production CLI & LaunchAgent daemon (`main.swift`, `Commands.swift`, `InitCommand.swift`, `CompletionsAndManCommands.swift`, `StatsCommand.swift`, `PauseCommands.swift`, `PeekCommand.swift`, `PeekController.swift`, `PeekOverlayWindow.swift`, `Daemon.swift`, `LaunchAgent.swift`); linked with embedded `__TEXT,__info_plist` from `Resources/Info.plist` |
| `Sources/hotkeyd-dev/` | Uninstalled interactive developer event-tap inspector (`listen`, `tap`, `modtap`); requires a foreground TTY (`tcgetpgrp`) |
| `Sources/selftest/` | Dependency-free executable test suite (no XCTest required; supports `--list` and `--filter <name>`) |
| `Resources/Info.plist` | Embedded Mach-O bundle metadata (`CFBundleIdentifier = io.github.jardondiego.hotkeyd`, `LSUIElement = true`) |
| `scripts/setup-signing.sh` | One-time generator for `~/Library/Keychains/hotkeyd-signing.keychain-db` (`Hotkeyd Local Signing` leaf cert) |
| `scripts/build.sh` | Release builder + Hardened Runtime (`CS_RUNTIME`) leaf-anchored signer + staged installer (`~/.local/bin/hotkeyd`) + refreshes `~/.local/share/man/man1/hotkeyd.1` |
| `scripts/test.sh` | Builds debug targets and runs `selftest` (forwards `--list` / `--filter <name>`) |
| `scripts/check.sh` | Canonical verification gate (`bash -n scripts/*.sh`, `git diff --check`, `./scripts/test.sh`, and `swift build -c release`; pass `--fast` to skip release build) |
| `docs/` | On-demand deep references: [docs/architecture.md](docs/architecture.md) (event-tap pipeline, lock ordering, Caps Lock, reload lifecycle) and [docs/security-model.md](docs/security-model.md) (threat model, trust boundaries, CodeTrust/StrictModes) |
| `skills/hotkeyd/SKILL.md` | Reusable Agent Skill teaching AI agents how to safely operate the `hotkeyd` CLI |

---

## Adding or Modifying a CLI Command (Checklist)

1. Put pure, launchd/TCC-free logic in `Sources/HotkeydCore/` so `selftest` can unit-test it directly.
2. Put substantial new CLI commands in their own file under `Sources/hotkeyd/` (like `InitCommand.swift` and `CompletionsAndManCommands.swift`) rather than bloating `Commands.swift`.
3. Synchronize [Commands.swift](Sources/hotkeyd/Commands.swift) (`dispatch`, `usage`), [CommandRegistry.swift](Sources/HotkeydCore/CommandRegistry.swift) (`commands`, `renderJSONSchema`), and [ManPageGenerator.swift](Sources/HotkeydCore/ManPageGenerator.swift) (section grouping). `describe --json`, `--help`, `completions` (`zsh`/`bash`/`fish`), and `man` all derive automatically from `CommandRegistry.commands`.
4. Use canonical exit codes only (`0` ok, `2` usage, `3` not found, `4` conflict/validation, `5` permission, `6` daemon, `7` config I/O/signing, `8` action failed). For commands with partial progress on non-zero exit (`doctor`, `init` exit `5`), emit `emitJSON(..., ok: false)` before `exit(code)`.
5. Keep production CLI zero-`termios` (cooked-mode `poll(2)` + `readLine` if interactive) and zero-ANSI escapes; fail closed with exit `2` on non-TTY interactive calls unless `--non-interactive` or `--dry-run` is passed.
6. Add unit + `HOTKEYD_HOME`-sandboxed CLI tests in [Sources/selftest/main.swift](Sources/selftest/main.swift) and update [README.md](README.md) (enforced by `testCommandRegistryAndSchemas`).

---

## Core Security Invariants (Do Not Regress)

1. **Pure Swift Only:** Do not introduce C targets or Objective-C bridges. Keep `Package.swift` on `.swiftLanguageMode(.v5)`. System calls (`responsibility_spawnattrs_setdisclaim`, `posix_spawn_file_actions_addchdir_np`, `IOHIDGetModifierLockState`, `IOHIDSetModifierLockState`) are bound directly in Swift inside `HotkeydCore`.
2. **TCC Responsibility Disclaim & Safe Process Spawning (`testV01SecurityControls`):** Never use `Foundation.Process()` in production `Sources/hotkeyd/`. Spawn children through `ShellRunner.spawnProcess` (`disclaimResponsibility: true`, `inheritStandardIO: true` for interactive TTY children like `edit`) or `ShellRunner.runSystemTool` (bounded timeout, zero zombie leaks). Never interpolate strings into AppleScript — pass arguments via `on run argv`. Disclaim unconditionally under `HOTKEYD_HOME` or `--allow-adhoc` (which also disables live `SelectionReader`). Prefer `NSWorkspace` fast-path commands (`open -a`, `open https://...`, `open <dir>`).
3. **Descriptor-Pinned `0600` Config & `StrictModes`:** `Config.load` verifies ancestors via `StrictModes.verifySecurePath`, opens parent dir (`O_DIRECTORY | O_NOFOLLOW`), opens `.hotkeyd` via `openat` (`O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK`), and verifies `fstat` (`S_ISREG`, `st_uid == getuid()`, `(st_mode & 0o077) == 0`, `<= 1 MiB`). Writes use `StrictModes.atomicWrite` (`0600`, checked `fsync`, `renameat`, dir `fsync`) under `Config.withExclusiveLock`.
4. **Hardened Runtime, Signing & Daemon Lifecycle (`testCodeTrustControls`, `testCriticalAndHighSecurityFixes`):** `CodeTrust.verify` (`kSecCSStrictValidate | kSecCSCheckAllArchitectures`) and `CodeTrust.verifyCurrentProcess` reject unsigned/tampered binaries, `/.build/` or `/tmp/` paths, missing `CS_RUNTIME`, any unexpected/relaxation/private entitlements, and ad-hoc/unanchored signatures unless `--allow-adhoc`. Always use documented `SecCodeStatus` / `SecCodeSignatureFlags` masks — never raw `<sys/codesign.h>` hex constants. Reload and peek/search signals go through `CodeTrust.verifyRunningProcess` + atomic `/bin/launchctl kill SIGHUP|SIGUSR1|SIGUSR2 gui/$UID/io.github.jardondiego.hotkeyd.daemon` (never raw `kill(pid, ...)`), with `0.15s` daemon rate-limiting on `SIGUSR1`/`SIGUSR2`/`.toggleSearch`. `Daemon.start()` holds an exclusive `0600` `O_NOFOLLOW` `flock` on `daemon.lock`; termination must call `RuntimeState.remove(at:expectedPID: getpid())`.
5. **No Keylogger Surface & Secure Event Input:** Event-tap listeners (`listen`, `tap`, `modtap`) stay exclusively in `Sources/hotkeyd-dev/main.swift` and must never be compiled into `Sources/hotkeyd/`. `Daemon.handle` resets state, dismisses any active Peek or Search HUD (`peekBridge.hide()` on `enteredSecureInput` and tap-disabled events even when `peekModeLocked == .idle`), and passes events through untouched (still swallowing remapped F18) whenever `Carbon.IsSecureEventInputEnabled()` is true; `PeekOverlayWindow.swift` also checks `!IsSecureEventInputEnabled()` before showing or executing. Because `Daemon` checks Secure Input lazily in tap callbacks, CLI commands needing fresh status (e.g., `init`) must call `Carbon.IsSecureEventInputEnabled()` directly.
6. **Bash 3.2 & Keychain Script Hygiene (`scripts/*.sh`):** macOS ships `/bin/bash` 3.2 (no associative arrays, no `mapfile`, quote empty array expansions under `set -u`). Never pass unvalidated env vars to `/usr/bin/security -i`; validate with `reject_control_chars` + `security_quote`, install `INT`/`TERM`/`HUP`/`EXIT` cleanup traps, and run `bash -n scripts/*.sh`.

---

## Known Gotchas & Threading Rules

- **`swift test` is unsupported** (CLT ships no XCTest / swift-testing); always use `./scripts/check.sh` or `./scripts/test.sh [--list | --filter <name>]`.
- **`ShellRunner.run` caps stdout/stderr at 4096 bytes (`maxCapturedBytes`):** Redirect large CLI outputs (`describe --json`, `man`, `completions`) to a temp file in `selftest` instead of asserting on `result.stdout`.
- **Swift types:** `Modifier` is a `struct` (switch on `(modifier.family, modifier.side)`), not an `enum`; `KeySequence` stores `keyCode` (`UInt16`), rendered via `KeyCodes.name(for:)`.
- **Daemon lock order:** `controlQueue` -> `lock`; never call `controlQueue.sync` or blocking I/O (`launchctl`, `hidutil`, shell) while holding `lock`.
- **Peek helper IPC & Release ARC safety:** `PeekOverlayBridge` writes NDJSON frames > 16 KiB over a non-blocking pipe via `DispatchSourceWrite` (always balance `suspend`/`resume` before `cancel()`) and retains per-PID `DispatchSourceProcess` reapers until `waitpid(2)` reaps each child. Inside `commandInternalPeekOverlay`, start the stdin reader before `NSApplication.shared` and wrap `app.run()` in `withExtendedLifetime(controller)` so Release `-O` ARC never frees the controller before `readStdinLoop()` runs.
- **AX prompt suppression:** One-shot suppression during `init` / `daemon install` uses the 15s `0600` `O_NOFOLLOW` `.suppress-ax-prompt` sentinel — do not persist prompt-suppression flags in the LaunchAgent plist.
- **Man page lint:** `selftest` runs strict `/usr/bin/mandoc -Tlint` (zero warnings, `<= 80`-byte source lines, literal ISO date in `.TH`), `/bin/zsh -n`, `/bin/bash -n`, and Python `pty` tests.
- **Deep dives:** Read [docs/architecture.md](docs/architecture.md) before modifying `Daemon`, detectors, `CapsLock`, or `ShellRunner`, and [docs/security-model.md](docs/security-model.md) before changing `CodeTrust`, `StrictModes`, `SelectionReader`, or `scripts/*.sh`.

---

## Verification & Live-Daemon Boundaries

Run from the repository root (`Package.swift` embeds `Resources/Info.plist` via a repo-relative linker path):

```bash
./scripts/check.sh                # full gate: bash -n, git diff --check, selftest, release build
./scripts/test.sh --filter init   # fast targeted iteration on one selftest suite
```

- **Sandbox isolation:** Always set `HOTKEYD_HOME` to a temporary `0700` directory when testing CLI commands so the user's live `~/.hotkeyd` and LaunchAgent are never touched.
- **Do not run `./scripts/build.sh` or live `hotkeyd daemon install|restart|stop|uninstall|panic` unattended** unless the user explicitly asks to install/restart the live daemon. When `hotkeyd-signing.keychain-db` is locked and stdin is not a TTY, `build.sh` exits `2`; instruct the user to run `cd ~/hotkeyd && ./scripts/build.sh && hotkeyd doctor` in an interactive terminal.
