#!/usr/bin/env zsh
# Terminal A spawn / teardown via tmux (NOT osascript).
#
# Some smoke steps drive the SUT through commands that need a real TTY
# (stty calls, `docker run -it`, etc.). The controller can't run them
# directly because its own stdin is the operator's terminal. tmux gives
# us a real pty in a detached session, with capture-pane for log
# inspection and kill-session for clean teardown.
#
# Each session is named `smoke-<slug>`. Pane output is also piped to
# `logs/${SECTION_NUM}-${slug}-pane.log` so SUT output survives even
# when the spawned process dies fast.
#
# Optional env knobs:
#   TERM_A_DOCKER_NAME_PREFIX  — passed to `docker ps --filter name=...`
#                                in the early-fail diagnostics. Defaults
#                                to "smoke-${SECTION_SLUG}". Override
#                                per-runner if your container naming
#                                differs.

: "${RUN_LOG:?RUN_LOG must be set}"

# term_a_start "<slug>" "<command>" [arg ...]
# Starts a detached tmux session running the given command. The command
# runs with a real pty and inherits the parent's environment. The session
# name is `smoke-<slug>`.
#
# For the common case of running the SUT against a project dir:
#     term_a_start "$slug" "$SUT_BIN" run "$pdir"
term_a_start() {
  local slug="$1"; shift
  local session="smoke-$slug"
  log "  TERM-A start  session=$session  cmd=\"$*\""

  # Kill any pre-existing session with this name (defensive — should never
  # exist because slugs are unique per section).
  tmux has-session -t "$session" 2>/dev/null && tmux kill-session -t "$session"

  # Start detached, large pane so log lines aren't truncated. Pipe pane
  # contents to a file so output survives even when the spawned command
  # dies fast (otherwise the tmux session ends before we can capture-pane).
  local pipe_log="$SCRIPT_DIR/logs/${SECTION_NUM}-${slug}-pane.log"
  : > "$pipe_log"
  tmux new-session -d -s "$session" -x 200 -y 50 "$@"
  tmux pipe-pane -t "$session" -o "cat >> $pipe_log" 2>/dev/null
  log "  TERM-A pipe   pane -> $pipe_log"
}

# term_a_wait_port "<port>" [timeout]
# Waits for the given TCP port on 127.0.0.1 to start listening. Returns
# 0 on success, 1 on timeout. On failure, dumps the pane log + docker
# state for triage.
term_a_wait_port() {
  local port="$1" timeout="${2:-30}"
  log "  TERM-A wait   port=$port timeout=${timeout}s"
  # Defensive: if the tmux session vanished before we even got here, the
  # spawned process died early. Snapshot what little we can immediately.
  local session="smoke-${SECTION_SLUG}"
  local docker_filter="${TERM_A_DOCKER_NAME_PREFIX:-smoke-${SECTION_SLUG}}"
  sleep 1
  if ! tmux has-session -t "$session" 2>/dev/null; then
    log "  EARLY-FAIL: tmux session '$session' is already gone after 1s"
    _term_a_dump_diagnostics "$session" "$docker_filter"
    fail "term-a session died before port came up"
    return 1
  fi
  if wait_for_port "$port" "$timeout"; then
    pass "term-a port $port up"
    return 0
  fi
  fail "term-a port $port did not come up within ${timeout}s"
  _term_a_dump_diagnostics "$session" "$docker_filter"
  return 1
}

# Internal: dump pane log + docker state + docker logs for the matched
# container. Called from term_a_wait_port on any failure path.
_term_a_dump_diagnostics() {
  local session="$1" docker_filter="$2"
  if tmux has-session -t "$session" 2>/dev/null; then
    log "  pane snapshot:"
    tmux capture-pane -t "$session" -p 2>/dev/null | tail -40 \
      | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
  else
    log "  pane snapshot: tmux session '$session' not present"
    log "  tmux ls:"
    tmux ls 2>&1 | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
    local pipe_log="$SCRIPT_DIR/logs/${SECTION_NUM}-${SECTION_SLUG}-pane.log"
    if [[ -f "$pipe_log" ]]; then
      log "  pane log ($pipe_log):"
      tail -40 "$pipe_log" | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
    fi
  fi
  log "  docker ps -a (filter: name=$docker_filter):"
  docker ps -a --filter "name=$docker_filter" --format '{{.Names}} {{.Status}}' \
    2>&1 | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
  local cname
  cname=$(docker ps -a --filter "name=$docker_filter" --format '{{.Names}}' | head -1)
  if [[ -n "$cname" ]]; then
    log "  docker logs $cname (last 40 lines):"
    docker logs --tail 40 "$cname" 2>&1 | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
  fi
}

# term_a_capture "<slug>" — dump pane content to RUN_LOG (debugging).
term_a_capture() {
  local slug="$1"
  local session="smoke-$slug"
  if tmux has-session -t "$session" 2>/dev/null; then
    log "  TERM-A pane (session=$session):"
    tmux capture-pane -t "$session" -p 2>/dev/null | sed 's/^/    /' | tee -a "$RUN_LOG" >/dev/null
  else
    log "  TERM-A pane: session $session not present"
  fi
}

# term_a_pane_grep "<slug>" "<pattern>" [timeout]
# Polls the tmux pane for a regex pattern. Returns 0 on match, 1 on timeout.
term_a_pane_grep() {
  local slug="$1" pattern="$2" timeout="${3:-30}"
  local session="smoke-$slug"
  local elapsed=0
  while (( elapsed < timeout )); do
    if tmux has-session -t "$session" 2>/dev/null; then
      if tmux capture-pane -t "$session" -p 2>/dev/null | grep -qE "$pattern"; then
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  return 1
}

# term_a_close "<slug>"
# Kills the tmux session, which sends SIGHUP to the spawned process tree.
term_a_close() {
  local slug="$1"
  local session="smoke-$slug"
  log "  TERM-A close  session=$session"
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session" 2>>"$RUN_LOG"
  else
    log "  TERM-A: no session to close"
  fi
}
