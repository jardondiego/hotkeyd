# Security Policy

Because `hotkeyd` runs as a per-user macOS LaunchAgent holding Accessibility (`kTCCServiceAccessibility`) permission, security vulnerabilities — especially TCC confused-deputy escalation, binary/config TOCTOU, Secure Event Input bypasses, and command or terminal injection — are treated seriously.

For the full threat model and trust-boundary design, see [docs/security-model.md](docs/security-model.md).

## Supported Versions

| Version | Supported |
| :--- | :--- |
| `0.1.x` / `main` | Yes |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report privately via **GitHub Security Advisories** ("Security" → "Advisories" → "Report a vulnerability" on `jardondiego/hotkeyd`).

Include, if possible:
- A concise description of the issue and affected component/file
- Reproduction steps or proof-of-concept (isolated with `HOTKEYD_HOME` when applicable)
- macOS version and signing mode (`scripts/build.sh` leaf-anchored vs `--allow-adhoc`)

You can expect an acknowledgement within **3 business days** and coordinated disclosure once a fix and regression test are verified.

## Out of Scope

- Arbitrary commands intentionally authored by the user inside their own mode-`0600` `~/.hotkeyd` file (Hotkeyd treats the user's own login session and `0600` `~/.hotkeyd` as trusted; see [docs/security-model.md](docs/security-model.md#7-known-trade-offs--future-hardening-backlog)).
- `--allow-adhoc` local development builds (which intentionally disable `SELECTED_TEXT` and child Accessibility delegation while keeping `CS_RUNTIME` mandatory).
