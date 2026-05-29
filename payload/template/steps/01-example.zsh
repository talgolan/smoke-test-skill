#!/usr/bin/env zsh
# {{TOPIC}} §1: example — proves the runner skeleton wires up.
#
# Demonstrates the rules from AUTHORING_GUIDE.md:
#   - Absolute paths everywhere (sub-shells drop cwd).
#   - RUN_OUT not `out` for caller captures (verify uses local out).
#   - verify for gates, log for info, pass/fail for explicit results.
#
# Replace this content with a real test once the skeleton is verified.

set -u
emulate -L zsh

# Per-section project dir; absolute path (sub-shell safe).
pdir="$SMOKE_ROOT/{{TOPIC}}-s${SECTION_NUM}"

sect "{{TOPIC}} §${SECTION_NUM}: example"

# --- Setup ---
mkdir -p "$pdir"
if [[ -d "$pdir" ]]; then
  pass "setup: pdir exists"
else
  fail "setup: pdir missing"
  exit 1
fi

# --- Steps ---
verify "binary executable" "test -x \"\$SUT_BIN\""
verify "version prints"    "\"\$SUT_BIN\" --version"

# RUN_OUT pattern: capture into caller var (NOT `out` — verify's local out shadows).
RUN_OUT=$("$SUT_BIN" --version 2>&1)
log "  version output: $RUN_OUT"

# --- Teardown ---
rm -rf "$pdir"
exit 0
