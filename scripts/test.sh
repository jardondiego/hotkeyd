#!/usr/bin/env bash
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset HOTKEYD_HOME
cd "$(dirname "$0")/.."

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  cat <<'EOF'
Usage: ./scripts/test.sh [--list | --filter <substring> | --help]

Builds all debug targets and runs the dependency-free selftest suite.
Pass --list to print available test suites, or --filter <substring> to run a subset.
EOF
  exit 0
fi

SWIFT="$(/usr/bin/xcrun --find swift)"

# Command Line Tools have no XCTest and no swift-testing module, so the suite is an executable
# target instead of `swift test`. Build all targets first so `selftest` can also exercise the
# compiled `hotkeyd` CLI binary end-to-end in a sandboxed HOTKEYD_HOME.
"$SWIFT" build -c debug
BIN_DIR="$("$SWIFT" build -c debug --show-bin-path)"
if [[ -f "$BIN_DIR/hotkeyd-dev" ]]; then
  chmod 0700 "$BIN_DIR/hotkeyd-dev"
fi
"$BIN_DIR/selftest" "$@"
