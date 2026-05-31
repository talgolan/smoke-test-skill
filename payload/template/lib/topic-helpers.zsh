#!/usr/bin/env zsh
# {{TOPIC}}-specific helpers.
#
# run.zsh auto-sources every <topic>/lib/*.zsh file AFTER the shared lib/,
# in BOTH the top-level controller AND the per-section alarm sub-shell — so
# any function you define here is available to your step files with no extra
# wiring. (Generic helpers that any SUT could use belong in the shared lib/,
# not here — see AUTHORING_GUIDE §11.)
#
# Expose helpers as top-level functions (no `local` on the function name).
# Document any env vars the helper reads at the top of the function.
#
# Example — a readiness probe specific to this SUT:
#
#   # {{TOPIC}}_wait_ready <name> [timeout]
#   {{TOPIC}}_wait_ready() {
#     local name="$1" timeout="${2:-30}" elapsed=0
#     while (( elapsed < timeout )); do
#       my-sut status "$name" >/dev/null 2>&1 && return 0
#       sleep 1; elapsed=$((elapsed + 1))
#     done
#     return 1
#   }
#
# Delete this file if the runner needs no project-specific helpers.
