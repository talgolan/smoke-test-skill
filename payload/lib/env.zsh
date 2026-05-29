#!/usr/bin/env zsh
# Generic smoke-test environment.
# Sourced by every runner's run.zsh AFTER `.smokerc` (which sets the
# SUT_BIN / SUT_REPO / BUILD_CMD vars this file validates).
#
# Required (must be set AND non-empty in .smokerc):
#   SUT_BIN     — absolute path to the binary under test
#   SUT_REPO    — absolute path to the repo root (must be a directory)
#   BUILD_CMD   — shell command run from $SUT_REPO to (re)build $SUT_BIN
#
# Optional with defaults:
#   SMOKE_ROOT  — base dir for per-section project dirs (default: ~/smoke)
#
# Helpers:
#   wait_for_port <port> [timeout]
#       Waits until 127.0.0.1:<port> has a listener. Returns 0 on
#       success, 1 on timeout.

: "${SUT_BIN:?SUT_BIN must be set in .smokerc}"
: "${SUT_REPO:?SUT_REPO must be set in .smokerc}"
: "${BUILD_CMD:?BUILD_CMD must be set in .smokerc}"

# Empty-string guard: :? only catches unset, not empty.
[[ -n "$SUT_BIN" && -n "$SUT_REPO" && -n "$BUILD_CMD" ]] || {
  print -u2 "FATAL: SUT_BIN, SUT_REPO, and BUILD_CMD must be non-empty in .smokerc"
  exit 2
}

[[ -d "$SUT_REPO" ]] || {
  print -u2 "FATAL: SUT_REPO ($SUT_REPO) is not a directory"
  exit 2
}

SMOKE_ROOT="${SMOKE_ROOT:-$HOME/smoke}"

[[ -x "$SUT_BIN" ]] || {
  print -u2 "FATAL: $SUT_BIN not executable. Build first:"
  print -u2 "  cd $SUT_REPO && $BUILD_CMD"
  exit 2
}

mkdir -p "$SMOKE_ROOT"

wait_for_port() {
  local port="$1" timeout="${2:-90}" elapsed=0
  while (( elapsed < timeout )); do
    if lsof -iTCP:"$port" -sTCP:LISTEN -n 2>/dev/null | grep -q LISTEN; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  return 1
}
