#!/usr/bin/env zsh
# {{TOPIC}} smoke runner — controller.
#
# Created by `/smoke-add <topic>` (or `/smoke-init` for the first
# runner). Override ALL_SECTIONS and add steps under steps/.
#
# Usage:
#   ./run.zsh                 # run all auto sections
#   ./run.zsh --all           # include MANUAL_SECTIONS
#   ./run.zsh 01 03 05        # run a subset
#   ./run.zsh --list          # show section list with [manual] tags
#
# Output goes to logs/run-<timestamp>.log AND stdout.
# Old logs auto-pruned: keep last $RUN_LOG_KEEP (default 3; 0=off).
#
# Per-section budget: $BUDGET_DEFAULT (default 30s); sections that need
# more declare `# BUDGET_SECONDS=N` near top of step file. The
# BUDGET_SECONDS env var overrides globally (0 disables enforcement).

set -u
emulate -L zsh

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

# Resolve install path by walking up from $SCRIPT_DIR until we find
# `.smokerc`. Halt at the first `.git` dir (repo boundary) or at $HOME.
# Refuse if no `.smokerc` found within those bounds.
_find_install_dir() {
  local d="$SCRIPT_DIR"
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -f "$d/.smokerc" ]] && { print -r -- "$d"; return 0; }
    [[ -d "$d/.git" || "$d" == "$HOME" ]] && {
      print -u2 "FATAL: no .smokerc found from $SCRIPT_DIR upward (stopped at $d)"
      return 2
    }
    d="${d:h}"
  done
  print -u2 "FATAL: no .smokerc found from $SCRIPT_DIR upward (reached /)"
  return 2
}

INSTALL_DIR="$(_find_install_dir)" || exit 2
SMOKE_LIB="$INSTALL_DIR/lib"

# Source .smokerc BEFORE lib/ — lib/env.zsh validates the values it sets.
source "$INSTALL_DIR/.smokerc"

# Export config so per-section sub-shells inherit it.
export SUT_BIN SUT_REPO BUILD_CMD SMOKE_ROOT
[[ -n "${BUDGET_DEFAULT:-}" ]] && export BUDGET_DEFAULT
[[ -n "${RUN_LOG_KEEP:-}" ]] && export RUN_LOG_KEEP

mkdir -p logs

LOG_KEEP="${RUN_LOG_KEEP:-3}"
if (( LOG_KEEP > 0 )); then
  setopt local_options null_glob
  run_logs=("$SCRIPT_DIR/logs/"run-*.log)
  if (( ${#run_logs} > LOG_KEEP )); then
    print -lr -- "${run_logs[@]}" | xargs -I{} stat -f '%m %N' "{}" \
      | sort -rn | tail -n +$((LOG_KEEP + 1)) | cut -d' ' -f2- \
      | xargs -I{} rm -f -- "{}"
  fi
  term_logs=("$SCRIPT_DIR/logs/"*-pane.log)
  if (( ${#term_logs} > LOG_KEEP )); then
    print -lr -- "${term_logs[@]}" | xargs -I{} stat -f '%m %N' "{}" \
      | sort -rn | tail -n +$((LOG_KEEP + 1)) | cut -d' ' -f2- \
      | xargs -I{} rm -f -- "{}"
  fi
fi

RUN_LOG="$SCRIPT_DIR/logs/run-$(date +%Y%m%d-%H%M%S).log"
export RUN_LOG SCRIPT_DIR SMOKE_LIB INSTALL_DIR

source "$SMOKE_LIB/log.zsh"
source "$SMOKE_LIB/env.zsh"
source "$SMOKE_LIB/term-a.zsh"
source "$SMOKE_LIB/pause.zsh"

# Sections, in declared order. Add a step by adding `steps/NN-*.zsh`
# and appending it here.
typeset -ga ALL_SECTIONS=(
  "01-example"
)

# Sections excluded from the no-arg run (run with --all or by name).
typeset -ga MANUAL_SECTIONS=(
  # "NN-name"  # reason
)

if (( $# > 0 )) && [[ "$1" == "--list" ]]; then
  for s in "${ALL_SECTIONS[@]}"; do
    if (( ${MANUAL_SECTIONS[(I)$s]} )); then
      printf '%-32s [manual]\n' "$s"
    else
      printf '%s\n' "$s"
    fi
  done
  exit 0
fi
if (( $# > 0 )) && [[ "$1" == "--all" ]]; then
  shift; ALL=true
else
  ALL=false
fi

typeset -a SECTIONS_TO_RUN
if (( $# > 0 )); then
  for arg in "$@"; do
    local match=""
    for s in "${ALL_SECTIONS[@]}"; do
      if [[ "$s" == "$arg"* ]] || [[ "$s" == ${(l:2::0:)arg}-* ]]; then
        match="$s"; break
      fi
    done
    if [[ -z "$match" ]]; then
      print -u2 "ERROR: no section matches '$arg'"; exit 2
    fi
    SECTIONS_TO_RUN+=("$match")
  done
else
  for s in "${ALL_SECTIONS[@]}"; do
    if $ALL || ! (( ${MANUAL_SECTIONS[(I)$s]} )); then
      SECTIONS_TO_RUN+=("$s")
    fi
  done
fi

sect "Smoke run"
log "  log file:    $RUN_LOG"
log "  SUT:         $SUT_BIN"
log "  SUT_REPO:    $SUT_REPO"
log "  install dir: $INSTALL_DIR"
log "  sections:    ${SECTIONS_TO_RUN[*]}"
log "  date:        $(date)"

sect "Preflight"
preflight_ok=true
typeset -a tools=("${PREFLIGHT_TOOLS[@]:-jq lsof tmux}")
for tool in "${tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "preflight: $tool present"
  else
    fail "preflight: $tool missing"; preflight_ok=false
  fi
done
$preflight_ok || { err "preflight failed; aborting"; exit 2 }
log "preflight OK"

# Optional pre_run hook
if typeset -f pre_run >/dev/null; then
  sect "pre_run hook"
  if pre_run; then
    pass "pre_run hook"
  else
    fail "pre_run hook (rc=$?); aborting"
    exit 2
  fi
fi

DEFAULT_BUDGET="${BUDGET_DEFAULT:-30}"

typeset -A SECTION_RESULT SECTION_DURATION
for section in "${SECTIONS_TO_RUN[@]}"; do
  step_file="$SCRIPT_DIR/steps/${section}.zsh"
  if [[ ! -f "$step_file" ]]; then
    sect "$section"
    fail "$section: step file missing ($step_file)"
    SECTION_RESULT[$section]="FAIL-missing"
    continue
  fi

  declared_budget=$(grep -oE '^# BUDGET_SECONDS=[0-9]+' "$step_file" | head -1 \
                    | grep -oE '[0-9]+')
  budget="${BUDGET_SECONDS:-${declared_budget:-$DEFAULT_BUDGET}}"

  sect "$section  (budget: ${budget}s)"
  start_ts=$(date +%s)
  /usr/bin/perl -e "alarm($budget); exec @ARGV" -- /bin/zsh -c "
    source '$SMOKE_LIB/log.zsh'
    source '$SMOKE_LIB/env.zsh'
    source '$SMOKE_LIB/term-a.zsh'
    source '$SMOKE_LIB/pause.zsh'
    SECTION_SLUG='${section#*-}'
    SECTION_NUM='${section%%-*}'
    export SECTION_SLUG SECTION_NUM RUN_LOG SCRIPT_DIR SMOKE_LIB INSTALL_DIR \
           SUT_BIN SUT_REPO BUILD_CMD SMOKE_ROOT
    source '$step_file'
  "
  rc=$?
  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))
  SECTION_DURATION[$section]=$duration

  if (( rc == 142 || rc == 14 )); then
    SECTION_RESULT[$section]="TIMEOUT (>${budget}s)"
    log "  ${section}: TIMEOUT after ${duration}s (budget ${budget}s)"
  elif (( rc == 0 )); then
    SECTION_RESULT[$section]="PASS"
    log "  ${section}: PASS in ${duration}s"
  else
    SECTION_RESULT[$section]="FAIL (rc=$rc)"
    log "  ${section}: FAIL in ${duration}s (rc=$rc)"
  fi
done

sect "Summary"
total_duration=0
for s in "${SECTIONS_TO_RUN[@]}"; do
  d="${SECTION_DURATION[$s]:-0}"
  total_duration=$((total_duration + d))
  printf "  %-30s %-22s %4ds\n" "$s" "${SECTION_RESULT[$s]:-(no result)}" "$d" \
    | tee -a "$RUN_LOG"
done
log ""
log "  total: ${total_duration}s"
log ""
log "  log: $RUN_LOG"

# Optional post_run hook (warn-only on failure; doesn't change exit code)
if typeset -f post_run >/dev/null; then
  sect "post_run hook"
  if post_run; then
    pass "post_run hook"
  else
    warn "post_run hook returned non-zero (rc=$?); summary already emitted"
  fi
fi

for s in "${SECTIONS_TO_RUN[@]}"; do
  [[ "${SECTION_RESULT[$s]}" == "PASS" ]] || exit 1
done
exit 0
