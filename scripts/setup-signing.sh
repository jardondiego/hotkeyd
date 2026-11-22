#!/usr/bin/env bash
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-signing.sh [--help]

Creates ~/Library/Keychains/hotkeyd-signing.keychain-db (mode 0600, auto-locked
after 300s) with a local "Hotkeyd Local Signing" code-signing certificate so
Accessibility grants survive rebuilds.

Environment variables:
  HOTKEYD_KEYCHAIN          Override keychain path
  HOTKEYD_SIGNING_PASSWORD  Non-interactive keychain password (optional)
EOF
}

if [[ $# -gt 1 ]]; then
  echo "error: unexpected extra arguments" >&2
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
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
fi

reject_control_chars() {
  local label="$1"
  local value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "error: $label must not contain newline or carriage-return characters" >&2
    exit 2
  fi
  if printf '%s' "$value" | /usr/bin/LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]'; then
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

KEYCHAIN="${HOTKEYD_KEYCHAIN:-$HOME/Library/Keychains/hotkeyd-signing.keychain-db}"
CERT_NAME="Hotkeyd Local Signing"
KEYCHAIN_DIR="$(/usr/bin/dirname "$KEYCHAIN")"

reject_control_chars "HOTKEYD_KEYCHAIN" "$KEYCHAIN"

if [[ -L "$KEYCHAIN_DIR" || -L "$KEYCHAIN" ]]; then
  echo "error: refusing symlinked keychain path ($KEYCHAIN)" >&2
  exit 1
fi

if [[ -f "$KEYCHAIN" ]]; then
  if /usr/bin/security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" >/dev/null 2>&1; then
    SHA1="$(/usr/bin/security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" | /usr/bin/awk '/SHA-1 hash:/ { print tolower($3); exit }')"
    /usr/bin/security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    echo "signing keychain already configured: $KEYCHAIN"
    echo "  identity  $CERT_NAME"
    echo "  leaf sha1 $SHA1"
    exit 0
  fi
fi

PASS="${HOTKEYD_SIGNING_PASSWORD:-}"
USE_GUI_AGENT=0
if [[ -z "$PASS" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    read -r -s -p "New password for $KEYCHAIN: " PASS
    echo ""
    read -r -s -p "Confirm password: " PASS_CONFIRM
    echo ""
    if [[ "$PASS" != "$PASS_CONFIRM" ]]; then
      echo "passwords do not match" >&2
      exit 2
    fi
    if [[ -z "$PASS" ]]; then
      echo "password must not be empty" >&2
      exit 2
    fi
  else
    USE_GUI_AGENT=1
  fi
fi

if [[ -n "$PASS" ]]; then
  reject_control_chars "keychain password" "$PASS"
fi

/bin/mkdir -p -m 0700 "$KEYCHAIN_DIR"
/bin/chmod go-w "$KEYCHAIN_DIR"

WORKDIR="$(/usr/bin/mktemp -d "$KEYCHAIN_DIR/.hotkeyd-signing.XXXXXX")"
/bin/chmod 0700 "$WORKDIR"
reject_control_chars "WORKDIR" "$WORKDIR"
cleanup() {
  /bin/rm -fP "$WORKDIR/pass.txt" "$WORKDIR/p12.pass" "$WORKDIR/key.pem" "$WORKDIR/identity.p12" 2>/dev/null || true
  /bin/rm -rf "$WORKDIR"
  /usr/bin/security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap cleanup EXIT

# Ephemeral 256-bit passphrase used solely to protect temporary key.pem / identity.p12 on disk.
# Write two newline-terminated lines because OpenSSL/LibreSSL `pkcs12 -export` reads two lines
# when `-passin` and `-passout` reference the same file BIO.
P12_PASS="$(/usr/bin/openssl rand -hex 32)"
P12_PASS_FILE="$WORKDIR/p12.pass"
printf '%s\n%s\n' "$P12_PASS" "$P12_PASS" >"$P12_PASS_FILE"
/bin/chmod 0600 "$P12_PASS_FILE"

Q_KEYCHAIN="$(security_quote "$KEYCHAIN")"
Q_P12_PATH="$(security_quote "$WORKDIR/identity.p12")"
Q_P12_PASS="$(security_quote "$P12_PASS")"

if [[ "$USE_GUI_AGENT" == "1" ]]; then
  if [[ ! -f "$KEYCHAIN" ]]; then
    /usr/bin/security create-keychain -P "$KEYCHAIN"
  fi
  /bin/chmod 0600 "$KEYCHAIN"
  /usr/bin/security set-keychain-settings -lut 300 "$KEYCHAIN"
else
  Q_PASS="$(security_quote "$PASS")"
  if [[ ! -f "$KEYCHAIN" ]]; then
    printf 'create-keychain -p %s %s\n' "$Q_PASS" "$Q_KEYCHAIN" | /usr/bin/security -i
  fi
  /bin/chmod 0600 "$KEYCHAIN"
  /usr/bin/security set-keychain-settings -lut 300 "$KEYCHAIN"
  printf 'unlock-keychain -p %s %s\n' "$Q_PASS" "$Q_KEYCHAIN" | /usr/bin/security -i
fi

cat >"$WORKDIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_cs
prompt = no

[dn]
CN = Hotkeyd Local Signing
O = Hotkeyd

[v3_cs]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 \
  -passout "file:$P12_PASS_FILE" \
  -keyout "$WORKDIR/key.pem" \
  -out "$WORKDIR/cert.pem" \
  -days 3650 \
  -config "$WORKDIR/openssl.cnf" >/dev/null 2>&1

/usr/bin/openssl pkcs12 -export \
  -out "$WORKDIR/identity.p12" \
  -inkey "$WORKDIR/key.pem" \
  -in "$WORKDIR/cert.pem" \
  -passin "file:$P12_PASS_FILE" \
  -passout "file:$P12_PASS_FILE" >/dev/null 2>&1

# Grant private-key ACL only to /usr/bin/codesign (never /usr/bin/security, preventing silent key export).
printf 'import %s -k %s -P %s -T /usr/bin/codesign -f pkcs12\n' \
  "$Q_P12_PATH" "$Q_KEYCHAIN" "$Q_P12_PASS" | /usr/bin/security -i >/dev/null

if [[ "$USE_GUI_AGENT" == "0" ]]; then
  printf 'set-key-partition-list -S apple-tool:,apple: -s -k %s %s\n' \
    "$Q_PASS" "$Q_KEYCHAIN" | /usr/bin/security -i >/dev/null
else
  echo "note: GUI keychain mode skipped set-key-partition-list; approve codesign's prompt on first build or re-run in a terminal" >&2
fi

SHA1="$(/usr/bin/openssl x509 -in "$WORKDIR/cert.pem" -noout -fingerprint -sha1 | /usr/bin/awk -F= '{ gsub(/:/, "", $2); print tolower($2) }')"
/usr/bin/security lock-keychain "$KEYCHAIN"

echo "hotkeyd signing setup complete"
echo "  keychain  $KEYCHAIN (locked, mode 0600, auto-lock 300s)"
echo "  identity  $CERT_NAME"
echo "  leaf sha1 $SHA1"
