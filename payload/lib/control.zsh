#!/usr/bin/env zsh
# Control-flow helpers: wait on dual signals, preserve evidence on failure.
# Sourced by every runner's run.zsh, top-level AND inside the per-section
# alarm sub-shell. No external state required.

# poll_until <success-cmd> <failure-cmd> <timeout> [interval]
#
# Poll BOTH a success and a failure signal. Returns as soon as either fires:
#   0  success-cmd succeeded (eval rc 0)
#   2  failure-cmd succeeded (eval rc 0) — a fast, definitive failure
#   1  neither fired within <timeout> seconds
#
# Both commands are eval'd (same host-side semantics as `verify`; see
# AUTHORING_GUIDE §8). Pass an empty failure-cmd ("") to poll success only —
# but prefer a real failure signal: success-only polling burns the whole
# timeout on any failure and can't distinguish "slow" from "broken".
#
#   # success: the binary appears; failure: poststart logged the harness id
#   poll_until \
#     "docker exec $NAME test -e /home/assistant/.local/bin/sf" \
#     "grep -qx sf $itb_home/.cache/failed-harnesses.txt" \
#     120 2
#   case $? in
#     0) pass "sf installed" ;;
#     2) fail "poststart reported sf install FAILED" ;;
#     *) fail "sf did not install within 120s (no success, no failure signal)" ;;
#   esac
poll_until() {
  local success_cmd="$1" failure_cmd="$2" timeout="$3" interval="${4:-2}"
  local elapsed=0
  (( interval < 1 )) && interval=1
  while (( elapsed < timeout )); do
    if eval "$success_cmd" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$failure_cmd" ]] && eval "$failure_cmd" >/dev/null 2>&1; then
      return 2
    fi
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
  return 1
}

# smoke_keep_on_fail — true when SMOKE_KEEP_ON_FAIL is set in the environment
# AND this section has recorded at least one failure. FAIL_COUNT is maintained
# by log.zsh's `fail`/`verify` and is live inside the per-section sub-shell.
#
# Guard teardown with it so a failed run leaves its diagnostic state intact
# (live container, isolated $HOME, capture files) for the operator to probe.
# Sections tear down on EVERY exit by default; without this guard, a failed run
# destroys its own evidence and each root cause costs another full rebuild.
#
#   if smoke_keep_on_fail; then
#     keep_on_fail_notice "container: $NAME" "itb_home: $itb_home"
#     exit 1
#   fi
#   # ... normal teardown ...
smoke_keep_on_fail() {
  [[ -n "${SMOKE_KEEP_ON_FAIL:-}" ]] && (( ${FAIL_COUNT:-0} > 0 ))
}

# keep_on_fail_notice <handle> [<handle> ...]
# Print the live diagnostic handles (container names, dirs, log paths) the
# operator can probe, then explain teardown was skipped. Call right before the
# `exit` in a smoke_keep_on_fail branch.
keep_on_fail_notice() {
  warn "SMOKE_KEEP_ON_FAIL active + section failed — skipping teardown. Probe:"
  local handle
  for handle in "$@"; do
    log "    $handle"
  done
}
