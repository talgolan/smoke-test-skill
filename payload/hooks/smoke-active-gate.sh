#!/usr/bin/env bash
#
# smoke-active-gate.sh — PreToolUse hook (Bash matcher).
#
# While a smoke run is active (a sentinel file exists, written by a smoke runner
# for the duration of its run), BLOCK any Bash command that would MUTATE the
# smoke environment out from under the running test:
#
#   container exec … / docker exec …   (in-container mutation: pkill, login, writes)
#   kill … / pkill …                    (killing host-helpers or SUT procs)
#   container delete|rm / docker rm|kill (tearing down the run's containers)
#
# Why: an agent "diagnosing" a live run by exec-ing into its container or killing
# its procs contaminates the test — stale procs holding ports, broken PATH, false
# PortInUse/timeout failures. The smoke runner OWNS the containers + helpers while
# it runs; the agent must READ state (container ls, lsof, ps, cat the run log),
# never mutate it. Passive "don't poke" rules lose to diagnostic confidence — only
# a gate holds.
#
# Sentinel path: $SMOKE_SENTINEL_FILE if exported, else $HOME/.smoke-run-active.
# The runner's run.zsh (Port 2b) writes the SAME path — keep the two in sync via
# SMOKE_SENTINEL_FILE if you override the default (itb sets it to
# $HOME/.itb/.smoke-run-active).
#
# Self-scoped: no sentinel → exit 0 (allow). Between runs, cleanup is fine.
# Read-only inspection (container ls/inspect, docker ps, lsof, ps, cat) is NOT
# matched — only the mutating verbs above.
#
# Escape hatch: prefix the command with `SMOKE_GATE_OVERRIDE=1 ` to bypass for
# a deliberate, owned action (the runner's own teardown is exempt anyway since it
# runs from zsh, not this Bash-tool path).
#
# Output contract: permissionDecision:"deny" blocks + shows reason. Exit 0 = allow.

set -euo pipefail

SENTINEL="${SMOKE_SENTINEL_FILE:-$HOME/.smoke-run-active}"

# No active smoke run → nothing to protect.
[ -f "$SENTINEL" ] || exit 0

payload="$(cat || true)"
[ -z "${payload:-}" ] && exit 0

# Extract the Bash command. Prefer jq — it parses the JSON correctly (decodes
# \n \" \uXXXX, and stops at the field boundary). The sed fallback is only for
# hosts without jq; it is greedy (a sibling field after "command" bleeds into
# the match) so it is deliberately the last resort, not the default.
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)"
else
  cmd="$(printf '%s' "$payload" \
    | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(.*)/\1/p' \
    | head -1)"
  # Un-escape the JSON string body so word-boundary greps see real text.
  cmd="$(printf '%s' "$cmd" | sed -E 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g')"
fi
[ -z "$cmd" ] && exit 0

# Explicit override.
case "$cmd" in *SMOKE_GATE_OVERRIDE=1*) exit 0 ;; esac

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# Mutating verbs against the smoke env. Word-boundary / token matches so a
# substring in a path or a read-only verb (container ls/inspect, docker ps)
# does not trip.
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])(container|docker)[[:space:]]+exec([^[:alnum:]]|$)'; then
  deny "A smoke run is ACTIVE ($SENTINEL). It owns the container — do NOT \`container/docker exec\` into it (that contaminates the test: stale procs holding ports, broken PATH, false failures). READ state instead: the run log, \`container ls\`, \`lsof -iTCP:<port>\`, \`ps\`. If you truly must mutate, stop the run first, or prefix SMOKE_GATE_OVERRIDE=1."
fi
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])(kill|pkill)([^[:alnum:]]|$)'; then
  deny "A smoke run is ACTIVE ($SENTINEL). Do NOT \`kill\`/\`pkill\` — you will kill the run's host-helpers or SUT procs and break it. Let the runner own process lifecycle; READ with \`ps\`/\`lsof\`. Stop the run first if you must, or prefix SMOKE_GATE_OVERRIDE=1."
fi
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])(container[[:space:]]+(delete|rm)|docker[[:space:]]+(rm|kill))([^[:alnum:]]|$)'; then
  deny "A smoke run is ACTIVE ($SENTINEL). Do NOT delete/remove its containers — the runner tears them down itself. READ state only. Stop the run first if you must, or prefix SMOKE_GATE_OVERRIDE=1."
fi

exit 0
