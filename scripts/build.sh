#!/usr/bin/env bash
set -euo pipefail
umask 077
ORIG_PATH="${PATH:-}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/build.sh [--adhoc] [--install | --no-restart | --help]

Builds a release hotkeyd binary, signs it with Hardened Runtime (CS_RUNTIME)
and a leaf-anchored designated requirement from hotkeyd-signing.keychain-db,
and installs it atomically to ~/.local/bin/hotkeyd (override with HOTKEYD_BIN).

Options:
  --adhoc       Skip the local certificate keychain and ad-hoc sign with
                Hardened Runtime (CS_RUNTIME). Handy for trying hotkeyd out,
                but macOS resets Accessibility permission on every rebuild
                and SELECTED_TEXT / --allow-accessibility stay disabled.
                Run ./scripts/setup-signing.sh to avoid both.
  --install     Install/bootstrap the LaunchAgent after building and signing
                (passes --allow-adhoc when combined with --adhoc)
  --no-restart  Install the binary without restarting a running LaunchAgent
  --help, -h    Show this help message
EOF
}

MODE=""
ADHOC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc)
      ADHOC=1
      ;;
    --install|--no-restart)
      if [[ -n "$MODE" && "$MODE" != "$1" ]]; then
        echo "error: cannot combine $MODE with $1" >&2
        usage >&2
        exit 2
      fi
      MODE="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

reject_control_chars() {
  local label="$1"
  local value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "error: $label must not contain newline or carriage-return characters" >&2
    exit 2
  fi
  if printf '%s' "$value" | LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]'; then
    echo "error: $label must not contain control characters" >&2
    exit 2
  fi
}

security_quote() {
  local s="$1"
  if [[ "$s" == *$'\n'* || "$s" == *$'\r'* ]]; then
    echo "error: refusing newline in security -i argument" >&2
    return 1
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

SWIFT="$(/usr/bin/xcrun --find swift)"
BUNDLE_ID="io.github.jardondiego.hotkeyd"
LABEL="io.github.jardondiego.hotkeyd.daemon"
DEST="${HOTKEYD_BIN:-$HOME/.local/bin/hotkeyd}"
DEST_DIR="$(/usr/bin/dirname "$DEST")"
KEYCHAIN="${HOTKEYD_KEYCHAIN:-$HOME/Library/Keychains/hotkeyd-signing.keychain-db}"
CERT_NAME="Hotkeyd Local Signing"

reject_control_chars "HOTKEYD_KEYCHAIN" "$KEYCHAIN"
if [[ -n "${HOTKEYD_SIGNING_PASSWORD:-}" ]]; then
  reject_control_chars "HOTKEYD_SIGNING_PASSWORD" "$HOTKEYD_SIGNING_PASSWORD"
fi

CERT_SHA1=""
ORIG_KEYCHAINS=()
STAGE_FILES=()
LOCK_ON_EXIT=0
KEYCHAIN_LIST_RESTORED=1

if [[ "$ADHOC" -eq 0 ]]; then
  if [[ -L "$KEYCHAIN" ]]; then
    echo "error: refusing symlinked signing keychain at $KEYCHAIN" >&2
    exit 1
  fi
  if [[ ! -f "$KEYCHAIN" ]]; then
    echo "error: signing keychain not found at $KEYCHAIN" >&2
    echo "run ./scripts/setup-signing.sh first (recommended — keeps macOS Accessibility across rebuilds)." >&2
    echo "or pass --adhoc to skip local certificate setup (resets Accessibility on rebuilds; disables SELECTED_TEXT)." >&2
    exit 1
  fi

  CERT_SHA1="$(/usr/bin/security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null | /usr/bin/awk '/SHA-1 hash:/ { print tolower($3); exit }')"
  if [[ -z "$CERT_SHA1" ]]; then
    echo "error: certificate '$CERT_NAME' not found in $KEYCHAIN" >&2
    echo "run ./scripts/setup-signing.sh first (or pass --adhoc to skip local certificate setup)." >&2
    exit 1
  fi

  while IFS= read -r line; do
    cleaned="$(printf '%s\n' "$line" | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
    if [[ -n "$cleaned" ]]; then
      ORIG_KEYCHAINS+=("$cleaned")
    fi
  done < <(/usr/bin/security list-keychains -d user)
  KEYCHAIN_LIST_RESTORED=0
fi

restore_and_lock_keychain() {
  if [[ "$ADHOC" -eq 0 && "$KEYCHAIN_LIST_RESTORED" == "0" ]]; then
    if [[ ${#ORIG_KEYCHAINS[@]} -gt 0 ]]; then
      /usr/bin/security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    fi
    KEYCHAIN_LIST_RESTORED=1
  fi
  if [[ "$LOCK_ON_EXIT" == "1" ]]; then
    /usr/bin/security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    LOCK_ON_EXIT=0
  fi
}
cleanup() {
  for f in "${STAGE_FILES[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && /bin/rm -f "$f" || true
  done
  restore_and_lock_keychain
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap cleanup EXIT

echo "hotkeyd build"
"$SWIFT" build -c release --product hotkeyd
RELEASE_BIN_DIR="$("$SWIFT" build -c release --show-bin-path)"
if [[ -f "$RELEASE_BIN_DIR/hotkeyd-dev" ]]; then
  /bin/chmod 0700 "$RELEASE_BIN_DIR/hotkeyd-dev"
fi

BIN="$RELEASE_BIN_DIR/hotkeyd"
REQ=""

if [[ "$ADHOC" -eq 0 ]]; then
  REQ="=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""

  LOCK_ON_EXIT=1
  if [[ -n "${HOTKEYD_SIGNING_PASSWORD:-}" ]]; then
    # Pipe via `security -i` stdin with pre-validated double-quoted escaping so the password never appears in `ps`.
    Q_PASS="$(security_quote "$HOTKEYD_SIGNING_PASSWORD")"
    Q_KEYCHAIN="$(security_quote "$KEYCHAIN")"
    printf 'unlock-keychain -p %s %s\n' "$Q_PASS" "$Q_KEYCHAIN" | /usr/bin/security -i
  elif ! /usr/bin/security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    # Note: in a macOS GUI session, `show-keychain-info` prompts via SecurityAgent and unlocks
    # `$KEYCHAIN` when approved; we only reach here if that dialog was cancelled or unavailable.
    if [[ ! -t 0 ]]; then
      echo "error: $KEYCHAIN remains locked (run ./scripts/build.sh in your terminal or approve the Keychain prompt)" >&2
      exit 2
    fi
    /usr/bin/security unlock-keychain "$KEYCHAIN"
  fi

  /usr/bin/security list-keychains -d user -s "$KEYCHAIN" "${ORIG_KEYCHAINS[@]}"
fi

install_staged_binary() {
  local target="$1"
  local target_dir
  target_dir="$(/usr/bin/dirname "$target")"
  if [[ -L "$target_dir" || -L "$target" ]]; then
    echo "error: refusing symlinked install path ($target)" >&2
    exit 1
  fi
  /bin/mkdir -p -m 0700 "$target_dir"
  /bin/chmod go-w "$target_dir"

  local stage
  stage="$(/usr/bin/mktemp "$target_dir/.hotkeyd.new.XXXXXX")"
  STAGE_FILES+=("$stage")
  /bin/cp "$BIN" "$stage"
  /bin/chmod 0755 "$stage"

  if [[ "$ADHOC" -eq 1 ]]; then
    /usr/bin/codesign --force \
      --sign - \
      --options runtime \
      --identifier "$BUNDLE_ID" \
      "$stage" >/dev/null
  else
    /usr/bin/codesign --force \
      --sign "$CERT_SHA1" \
      --keychain "$KEYCHAIN" \
      --options runtime \
      --timestamp=none \
      --identifier "$BUNDLE_ID" \
      --requirements "$REQ" \
      "$stage" >/dev/null
  fi

  /usr/bin/codesign --verify --deep --strict "$stage"
  /bin/mv -f "$stage" "$target"
}

install_staged_binary "$DEST"

# Lock the signing keychain immediately after signing completes (before daemon install/restart).
restore_and_lock_keychain

if [[ -z "${HOTKEYD_BIN:-}" && "$DEST" == "$HOME/.local/bin/hotkeyd" ]]; then
  if "$DEST" man --install >/dev/null 2>&1; then
    echo "  manpage  $HOME/.local/share/man/man1/hotkeyd.1"
  fi
fi

REQUIREMENT="$(/usr/bin/codesign -d -r- "$DEST" 2>&1 | /usr/bin/tail -1)"
echo "  binary   $DEST"
echo "  identity $REQUIREMENT"

if [[ "$ADHOC" -eq 1 ]]; then
  echo "  signing  ad-hoc + Hardened Runtime (--adhoc)"
  echo "  note     local certificate signing prevents macOS from resetting Accessibility on every rebuild"
  echo "           and enables SELECTED_TEXT / --allow-accessibility."
  echo "           switch anytime: ./scripts/setup-signing.sh && ./scripts/build.sh --install"
fi

if [[ -z "${HOTKEYD_BIN:-}" && "$DEST" != "$HOME/bin/hotkeyd" && -e "$HOME/bin/hotkeyd" ]]; then
  echo "  warning  found another copy at $HOME/bin/hotkeyd; remove it to avoid PATH shadowing" >&2
fi

ON_PATH=1
case ":$ORIG_PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    ON_PATH=0
    echo "  warning  $DEST_DIR is not on your PATH" >&2
    echo "  hint     add to ~/.zshrc: export PATH=\"$DEST_DIR:\$PATH\"" >&2
    ;;
esac

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PLIST_IS_ADHOC=0
if [[ -f "$PLIST" && ! -L "$PLIST" ]] && /usr/bin/grep -Fq '<string>--allow-adhoc</string>' "$PLIST"; then
  PLIST_IS_ADHOC=1
fi

DAEMON_INSTALLED=0
if [[ "$MODE" == "--install" ]]; then
  if [[ "$ADHOC" -eq 1 ]]; then
    "$DEST" daemon install --binary "$DEST" --allow-adhoc --no-open >/dev/null
    echo "  daemon   installed and running (--allow-adhoc)"
  else
    "$DEST" daemon install --binary "$DEST" --no-open >/dev/null
    echo "  daemon   installed and running"
  fi
  DAEMON_INSTALLED=1
  if ! "$DEST" doctor >/dev/null 2>&1; then
    echo "  action   enable \"hotkeyd\" in System Settings > Privacy & Security > Accessibility"
  fi
elif /bin/launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  DAEMON_INSTALLED=1
  if [[ "$MODE" != "--no-restart" ]]; then
    if [[ "$ADHOC" -eq 1 && "$PLIST_IS_ADHOC" -eq 0 ]]; then
      echo "  warning  installed LaunchAgent expects a certificate-signed binary; skipping restart" >&2
      echo "  hint     run ./scripts/build.sh --adhoc --install to switch the LaunchAgent to --allow-adhoc" >&2
    else
      "$DEST" daemon restart >/dev/null || true
      echo "  daemon   restarted"
      if [[ "$ADHOC" -eq 0 && "$PLIST_IS_ADHOC" -eq 1 ]]; then
        echo "  note     LaunchAgent still passes --allow-adhoc; run ./scripts/build.sh --install to switch to full signed mode" >&2
      elif [[ "$ADHOC" -eq 1 ]]; then
        echo "  note     ad-hoc rebuild changed the binary CDHash; re-toggle Accessibility in System Settings if shortcuts stop responding" >&2
      fi
    fi
  fi
fi

NEXT_SUBCMD="init"
if [[ "$DAEMON_INSTALLED" -eq 1 ]]; then
  NEXT_SUBCMD="doctor"
elif [[ "$ADHOC" -eq 1 ]]; then
  NEXT_SUBCMD="init --allow-adhoc"
fi

if [[ "$ON_PATH" -eq 1 ]]; then
  echo "  next     hotkeyd $NEXT_SUBCMD"
else
  echo "  next     export PATH=\"$DEST_DIR:\$PATH\" && hotkeyd $NEXT_SUBCMD"
fi
