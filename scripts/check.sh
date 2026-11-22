#!/usr/bin/env bash
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset HOTKEYD_HOME
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/check.sh [--fast | --help]

Canonical local and CI verification gate for hotkeyd:
  1. bash -n scripts/*.sh
  2. git diff --check
  3. ./scripts/test.sh (debug build + full selftest suite)
  4. swift build -c release (skipped with --fast)
EOF
}

FAST=0
if [[ $# -gt 1 ]]; then
  echo "error: unexpected extra arguments" >&2
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --fast)
      FAST=1
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
fi

SWIFT="$(/usr/bin/xcrun --find swift)"

echo "[check] 1/4 shell syntax (bash -n scripts/*.sh)"
/bin/bash -n scripts/*.sh

echo "[check] 2/4 whitespace & conflict markers (git diff --check)"
if /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  /usr/bin/git diff --check
fi

echo "[check] 3/4 debug build & selftest (./scripts/test.sh)"
./scripts/test.sh

if [[ "$FAST" == "0" ]]; then
  echo "[check] 4/4 release build (swift build -c release)"
  "$SWIFT" build -c release
else
  echo "[check] 4/4 release build skipped (--fast)"
fi

echo "[check] ok"
