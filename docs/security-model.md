# Hotkeyd Security Model

On-demand security architecture and threat-model reference for contributors and AI agents modifying CodeTrust, StrictModes, ShellRunner, SelectionReader, Daemon, LaunchAgent, or scripts/*.sh.

---

## 1. Threat Model & Security Goals

Hotkeyd runs as a per-user LaunchAgent holding macOS Accessibility (kTCCServiceAccessibility) permission. That privilege allows observing global keystrokes and querying focused UI elements. The security model defends against five primary threats:

1. **TCC Confused-Deputy Escalation:** Preventing unprivileged child scripts, editors, sandboxed CLI invocations (HOTKEYD_HOME), or other local processes from abusing Hotkeyd's Accessibility grant.
2. **Binary & Config Tampering / TOCTOU:** Preventing local symlink swaps, loose-permission config edits, debug/unsigned binary substitution, or stale-PID signal races.
3. **Password & Credential Leakage:** Preventing shortcuts from firing or stealing focus during Secure Event Input, preventing Caps Lock F18 keystroke leakage into password fields, and preventing SelectionReader from extracting sensitive text from secure fields or auth dialogs.
4. **Command & Script Injection:** Preventing shell metacharacters, NUL/newline injection, or AppleScript string interpolation across CLI actions, notifications, and build/signing scripts.
5. **Keychain & Signing Material Exposure:** Preventing signing passwords from appearing in process argument lists (ps / KERN_PROCARGS2) or leaving the local signing keychain unlocked.

---

## 2. Trust Boundaries

| Boundary | Enforcement Mechanism | Source of Truth |
| :--- | :--- | :--- |
| Production CLI/Daemon vs Developer Listeners | Event-tap keystroke inspectors (listen, tap, modtap) live only in uninstalled hotkeyd-dev (0700, foreground TTY via tcgetpgrp) and are never compiled into signed hotkeyd. | Sources/hotkeyd-dev/main.swift |
| Daemon vs Child Shell Processes | ShellRunner.spawnProcess sets responsibility_spawnattrs_setdisclaim by default so child shells disclaim kTCCServiceAccessibility. Opting in requires explicit allowAccessibility: true per shortcut, and is unconditionally blocked under HOTKEYD_HOME or --allow-adhoc. | Sources/HotkeydCore/ShellRunner.swift |
| Daemon vs Interactive Editors (hotkeyd edit) | Spawns user VISUAL/EDITOR via ShellRunner.spawnProcess with disclaimResponsibility: true, setProcessGroup: false, inheritStandardIO: true, and umask(0o077). Never uses Foundation.Process. | Sources/hotkeyd/Commands.swift |
| Daemon vs Peek Overlay & Search Helper (__peek-overlay) | Spawns a lazy child (only when peek.enabled == true) over a strictly one-way unnamed pipe(2) via ShellRunner.spawnProcess with disclaimResponsibility: true, POSIX_SPAWN_CLOEXEC_DEFAULT, F_SETNOSIGPIPE, and scrubbed environment (using Paths.realUserName and validated TMPDIR). Re-verifies binary StrictModes + CodeTrust.verify pre-spawn and CodeTrust.verifyRunningProcess on the child PID before writing any frame. Uses non-blocking DispatchSourceWrite framing (> 16 KiB safe, 2.0s stall timeout), 4-in-10s spawn rate-limiting, 0.15s signal rate-limiting, and persistent per-PID DispatchSourceProcess reaping (SIGTERM -> SIGKILL). Helper moves its pipe off STDIN_FILENO onto a private F_DUPFD_CLOEXEC descriptor, has zero reverse channel into the daemon, locks ShellRunner.disallowAccessibilityDelegation = true (the load-bearing boundary under the single-binary model alongside child /bin/zsh disclaim), omits rawCommand/cwd/timeout over the wire for [AX]/[SEL]/disabled bindings, independently re-checks !SelectionReader.commandUsesSelectedText, PauseState, and !Carbon.IsSecureEventInputEnabled(), recomputes command previews locally, marks ⌘⇧C pasteboard writes .currentHostOnly + TransientType (+ ConcealedType when secrets are redacted), clears Search items from RAM on hide, reads bounded (<= 256 KiB) NDJSON snapshots only, refuses interactive TTY execution, flushes logs on exit, and defers idle exit while child actions are in flight. | Sources/hotkeyd/PeekController.swift, Sources/hotkeyd/PeekOverlayWindow.swift, Sources/HotkeydCore/PeekModel.swift, Sources/HotkeydCore/PeekSearch.swift |
| Daemon vs Sandboxed Callers (HOTKEYD_HOME) | hotkeyd daemon run sets Paths.ignoreEnvironmentOverride = true and unsetenv("HOTKEYD_HOME") immediately; LaunchAgent operations refuse execution when HOTKEYD_HOME is set. | Sources/HotkeydCore/Paths.swift, Sources/hotkeyd/LaunchAgent.swift |
| Daemon vs Untrusted Directories & Symlinks | Ancestor walk from / via lstat(2) rejecting symlinks, . / .., untrusted owners, and go+w bits; file I/O pinned via openVerifiedDirectory + openat(O_NOFOLLOW) + fstat + renameat + checked fsync. | Sources/HotkeydCore/StrictModes.swift, Sources/HotkeydCore/Config.swift |

---

## 3. Code Signing & Runtime Trust (CodeTrust)

Every daemon startup, LaunchAgent install, reload, and doctor check enforces strict Mach-O code integrity via CodeTrust.swift:

- **Static & live verification:** SecStaticCodeCheckValidity with kSecCSStrictValidate | kSecCSCheckAllArchitectures (verifying executable page hashes, not basic metadata) plus SecCodeCopySelf live-process verification checking CS_VALID, CS_RUNTIME, !CS_DEBUGGED, and on-disk (st_dev, st_ino) identity matching.
- **Forbidden paths:** Rejects binaries under /.build/, /tmp/, /private/tmp/, /var/tmp/, and /private/var/tmp/ on both raw and symlink-resolved paths.
- **Hardened Runtime & zero relaxations:** CS_RUNTIME is mandatory even when --allow-adhoc is passed. Rejects get-task-allow, all Hardened Runtime relaxation entitlements (allow-dyld-environment-variables, disable-library-validation, allow-unsigned-executable-memory, disable-executable-page-protection, allow-jit, debugger), any com.apple.private.* entitlement, any unexpected truthy entitlement, and unparsed DER-only entitlements.
- **Designated requirement anchoring:** Production mode (allowAdhoc == false) rejects ad-hoc signatures and disjunctive (" or ") requirements, requiring a compiled conjunctive requirement matching identifier "io.github.jardondiego.hotkeyd" and the exact leaf certificate SHA-1 (certificate leaf = H"<sha1>") generated by scripts/setup-signing.sh.
  - *Future Homebrew Cask / Developer ID note:* Supporting third-party Apple Developer ID certificates will require adding an explicit anchor apple generic + Developer ID OID + pinned subject.OU = "<TEAM_ID>" branch in CodeTrust.swift alongside explicit handling for /Applications (0775 root:admin) in StrictModes.swift.
- **Safe masks:** Always use documented Security framework constants (SecCodeStatus.valid, SecCodeStatus.debugged, SecCodeSignatureFlags) rather than raw hex masks.
- **Atomic daemon signaling:** LaunchAgent.reload, notifyDaemonToReload, togglePeek, and togglePeekSearch verify the running PID via CodeTrust.verifyRunningProcess(pid:expectedBinaryPath:allowAdhoc:) anchored to the installed 0600 plist's binary path and ad-hoc flag, and signal through /bin/launchctl kill SIGHUP|SIGUSR1|SIGUSR2 gui/$UID/io.github.jardondiego.hotkeyd.daemon instead of raw kill(pid, ...). Daemon ignores managed signals before startup reload, gates SIGUSR1/SIGUSR2 on peek.enabled == true, and rate-limits SIGUSR1, SIGUSR2, and Search HUD toggles to 0.15s intervals on controlQueue.

---

## 4. Config, Logs, Filesystem & Process Isolation

- **~/.hotkeyd (Config.swift):** Opened with O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK from a verified directory descriptor; requires S_IFREG, st_uid == getuid(), mode 0600, and size <= 1 MiB. Symlinks (such as GNU Stow or chezmoi symlink mode) are refused with ELOOP; hotkeyd init offers safe validated copy-materialization to a regular 0600 file.
- **Atomic writes & locking:** Config mutations hold an exclusive flock lock and write via StrictModes.atomicWrite (0600 temp file -> checked fsync -> renameat -> parent dir fsync).
- **Safe folder & app launches (ShellRunner.swift):**
  - open <dir> pins the directory with O_RDONLY | O_DIRECTORY | O_NOFOLLOW + fcntl(F_GETPATH), rejects bundles/packages/aliases/symlinks, and opens plain folders via NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:) so bundles cannot be executed as folders.
  - open -a <App> searches system roots (/System/Applications, /Applications) across depths 0..2 ahead of user-writable ~/Applications, rejects /Volumes/, /tmp/, ~/Downloads/, ~/.Trash/, /.build/, rejects user-owned .app symlinks, and disables promptsUserIfNeeded and allowsRunningApplicationSubstitution.
- **Notifications & logs:** ShellRunner.notifyUser runs /usr/bin/osascript via ShellRunner.runSystemTool (5s timeout, zero zombie leaks) passing title and body strictly via on run argv (zero AppleScript interpolation). Log files (daemon.log, actions.log) are 0600, O_NOFOLLOW, rotated at 5 MiB, and stripped of ANSI/control characters. StatsAnalyzer (readVerifiedLogFile and logsFingerprint) verifies directory ancestors via StrictModes.verifySecurePath (when not in a HOTKEYD_HOME override), pins files with openat(O_NOFOLLOW | O_NONBLOCK) / fstatat(AT_SYMLINK_NOFOLLOW), enforces S_IFREG, st_uid == getuid(), mode 0600, and <= 6 MiB read bounds, uses an allocation-free RFC 3339 parser, and caches Search HUD usage tallies by (dev, ino, size, mtime) fingerprint so signal bursts cannot stall controlQueue.

---

## 5. Secure Event Input & SELECTED_TEXT Privacy

- **Secure Event Input blackout:** Daemon.handle checks Carbon.IsSecureEventInputEnabled() on every event, immediately clearing held modifiers, double-tap state, sequence state, pending key taps, and dismissing any active Peek overlay or Spotlight Search HUD (dispatching peekBridge.hide() on enteredSecureInput and tap-disabled events even when peekModeLocked == .idle) so password typing (sudo, 1Password, SecurityAgent) can never fire gestures or steal focus. While Caps Lock is remapped to F18, F18 keyDown/keyUp events remain swallowed during Secure Input so raw F18 never leaks into password fields. Daemon.applyPeekEffect, SIGUSR1, SIGUSR2, and the UI helper itself (PeekOverlayWindow.swift: showPeek, toggleSearch, showSearch, activateSelectedSearchItem) independently gate on !IsSecureEventInputEnabled().
- **SELECTED_TEXT boundary (SelectionReader.swift):**
  - Only runs when a shortcut command explicitly contains SELECTED_TEXT, never under HOTKEYD_HOME or --allow-adhoc, and never while IsSecureEventInputEnabled() is true.
  - Blocks known auth/password-manager/security UIs by denylist, uses bounded AXUIElementCopyAttributeValues queries, and aborts immediately when encountering AXSecureTextField.
  - Does not touch the user's clipboard and does not require granting --allow-accessibility to the child shell.

---

## 6. Build & Signing Script Hardening

Both scripts/setup-signing.sh and scripts/build.sh enforce:
- Pinned system PATH (/usr/bin:/bin:/usr/sbin:/sbin), umask 077, and Bash 3.2 compatibility.
- Strict control-character/newline rejection (reject_control_chars + security_quote) before piping commands into /usr/bin/security -i stdin (passwords never appear in argv).
- Temporary staging files created inside user-owned 0700 directories and cleaned up via INT/TERM/HUP + EXIT traps alongside immediate keychain relocking and user keychain search-list restoration.
- Private key ACL excludes -T /usr/bin/security so other scripts cannot export signing material silently.

---

## 7. Known Trade-Offs & Future Hardening Backlog

Deliberate boundaries and remaining lower-severity defense-in-depth items to keep in mind:

- **--allow-adhoc degraded mode:** Explicitly opted into for local development only; keeps CS_RUNTIME mandatory while disabling SELECTED_TEXT and child Accessibility delegation.
- **Command logs tailing:** hotkeyd logs --follow tracks (inode, offset) across rotations; migrating its FileHandle reader to descriptor-pinned O_NOFOLLOW openat is a clean future hardening step.
- **Developer ID & Cask packaging:** When adding Homebrew Cask distribution, update CodeTrust.swift for anchor apple generic + pinned Team ID and keep StrictModes' /Applications exception strictly gated on verified Developer ID signatures.
- **Separate peek helper binary:** Under the current single-binary install, `__peek-overlay` executes the same signed `hotkeyd` binary (so macOS TCC still considers the helper process itself Accessibility-trusted, relying on `ShellRunner.disallowAccessibilityDelegation = true` + child `/bin/zsh` disclaim as the boundary). Splitting the UI into a distinct `hotkeyd-peek-helper` binary with its own signing identifier never granted Accessibility is a clean post-0.1.0 hardening upgrade.
- **Single-user trust boundary:** Hotkeyd assumes the user's own login session and 0600 ~/.hotkeyd file are trusted; arbitrary shell commands explicitly written by the user in ~/.hotkeyd execute as that user.
