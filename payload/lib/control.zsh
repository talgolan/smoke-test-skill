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

# cap <seconds> <cmd> [args...]
#
# Run <cmd> under a hard per-command timeout. Returns the command's real exit
# code if it finishes within <seconds>, or 124 (the coreutils `timeout`
# convention) if it had to be killed. stdout/stderr flow through unchanged, so
# `OUT=$(cap 10 svc status)` captures normally.
#
# This is the per-COMMAND analogue of run.zsh's per-SECTION `alarm` budget. Use
# it for any hang-prone system call — daemon/service control verbs
# (`start`/`stop`/`status`), network probes, anything that can block on an
# unhealthy backend. Without it, one wedged call eats the whole section budget
# and the runner looks dead. Treat a 124 as a failure signal.
#
#   cap 25 docker stop "$NAME"            # rc 124 if docker hangs on a sick daemon
#   OUT=$(cap 10 container system status) # status output captured; 124 if wedged
#   cap 25 mytool up || fail "up timed out / failed (rc=$?)"
cap() {
  emulate -L zsh
  local secs="$1"; shift
  (( secs < 1 )) && secs=1

  # A marker file disambiguates "killed by the watchdog" (→ 124) from "the
  # command itself exited non-zero" — a signal-based rc check can't tell them
  # apart. Self-cleaning; honors the file's "no external state" contract.
  local marker
  marker=$(mktemp 2>/dev/null) || marker="${TMPDIR:-/tmp}/cap.$$"

  "$@" &
  local cmd_pid=$!

  ( sleep "$secs"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      print -n 1 > "$marker"
      kill -TERM "$cmd_pid" 2>/dev/null
      sleep 1
      kill -KILL "$cmd_pid" 2>/dev/null
    fi ) &
  local watcher_pid=$!

  wait "$cmd_pid" 2>/dev/null
  local rc=$?

  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null

  if [[ -s "$marker" ]]; then
    command rm -f "$marker" 2>/dev/null
    return 124
  fi
  command rm -f "$marker" 2>/dev/null
  return $rc
}
