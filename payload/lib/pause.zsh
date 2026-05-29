#!/usr/bin/env zsh
# Operator pause: prints instructions, waits for keypress.
# Used for steps that genuinely cannot be scripted (VS Code Remote-SSH §12,
# any optional human-eyeball verifications).

: ${RUN_LOG:?RUN_LOG must be set}

# pause "<headline>" "<multi-line-instructions>"
pause() {
  local headline="$1" body="$2"
  print -r -- "" | tee -a "$RUN_LOG" >/dev/null
  print -r -- "----- OPERATOR ACTION REQUIRED -----" | tee -a "$RUN_LOG"
  print -r -- "  $headline" | tee -a "$RUN_LOG"
  print -r -- "" | tee -a "$RUN_LOG"
  print -r -- "$body" | sed 's/^/  /' | tee -a "$RUN_LOG"
  print -r -- "" | tee -a "$RUN_LOG"
  print -r -- "Press [Enter] when done, or type 'skip' + Enter to mark this step SKIP, or 'fail' to mark FAIL."
  print -r -- "------------------------------------"
  local reply
  # Read from /dev/tty so the prompt works even when run.zsh's stdin is
  # piped (e.g. CI / `tee` upstream).
  print -n -- "> "
  read -r reply </dev/tty
  case "$reply" in
    skip|SKIP) skip "$headline (operator skipped)"; return 2 ;;
    fail|FAIL) fail "$headline (operator marked fail)"; return 1 ;;
    *) pass "$headline (operator confirmed)"; return 0 ;;
  esac
}

# confirm "<question>"
# Yes/no prompt. Returns 0 for yes, 1 for no.
confirm() {
  local q="$1" reply
  print -r -- "" | tee -a "$RUN_LOG" >/dev/null
  print -r -- "  $q [y/N] " | tee -a "$RUN_LOG"
  read -r reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) log "  operator: yes"; return 0 ;;
    *)            log "  operator: no";  return 1 ;;
  esac
}
