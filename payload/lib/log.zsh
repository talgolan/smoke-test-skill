#!/usr/bin/env zsh
# Log helpers: tee everything to RUN_LOG + stdout, with timestamps.
# RUN_LOG must be exported by run.zsh before sourcing.

: ${RUN_LOG:?RUN_LOG must be set}

_ts() { date +'%Y-%m-%dT%H:%M:%S%z' }

log()   { print -r -- "[$(_ts)] $*" | tee -a "$RUN_LOG" }
info()  { log "INFO  $*" }
warn()  { log "WARN  $*" }
err()   { log "ERROR $*" }
sect()  { log ""; log "=== $* ==="; log "" }

# pass/fail counters for the run summary
typeset -gi PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0
typeset -ga FAIL_NAMES=()

pass() {
  PASS_COUNT=$((PASS_COUNT+1))
  log "  PASS  $*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT+1))
  FAIL_NAMES+=("$1")
  log "  FAIL  $*"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT+1))
  log "  SKIP  $*"
}

# verify "label" "command-string"
# runs the command via eval, captures stdout+stderr+exit, logs it, and emits
# pass/fail line. The command should already encode its expected check, e.g.
#   verify "edit-applied" "tail -3 file | grep -q drift-test"
verify() {
  local label="$1" cmd="$2"
  local out rc
  out=$(eval "$cmd" 2>&1)
  rc=$?
  if [[ -n "$out" ]]; then
    print -r -- "$out" | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
  fi
  if (( rc == 0 )); then
    pass "$label"
    return 0
  else
    fail "$label  (rc=$rc)"
    return 1
  fi
}

# run "label" "command-string"
# log the command + its output + exit code; do NOT pass/fail. Use for
# informational steps (e.g. printing .itb.json contents).
run() {
  local label="$1" cmd="$2"
  log "  RUN   $label"
  log "        $ $cmd"
  local out rc
  out=$(eval "$cmd" 2>&1)
  rc=$?
  if [[ -n "$out" ]]; then
    print -r -- "$out" | sed 's/^/        /' | tee -a "$RUN_LOG" >/dev/null
  fi
  log "        exit=$rc"
  return $rc
}
