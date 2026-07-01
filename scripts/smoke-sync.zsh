#!/usr/bin/env zsh
# /smoke-sync — refresh ONLY the shared lib + AUTHORING_GUIDE in an existing
# install, with no new runner. The lib is committed into the consumer repo and
# can only be updated from the skill side (the runner has no path to the skill
# payload); smoke-add already version-gate-syncs it, but requires a --topic.
# This command is that sync, decoupled from scaffolding.
#
# Usage:
#   smoke-sync.zsh                       # walk up from $PWD for .smokerc
#   smoke-sync.zsh --install-path <path> # explicit install dir
#
# Discovery + version-gating are shared with smoke-add via lib-sync.zsh, so the
# two can't drift. Never downgrades a lib that's newer than the skill.

set -u
emulate -L zsh

SCRIPT_DIR="${0:A:h}"
PAYLOAD="$(cd "$SCRIPT_DIR/.." && pwd)/payload"
source "$SCRIPT_DIR/lib-sync.zsh"

install_path=""
while (( $# > 0 )); do
  case "$1" in
    --install-path) install_path="$2"; shift 2 ;;
    *) print -u2 "ERROR: unknown arg: $1"; exit 2 ;;
  esac
done

abs_install=$(resolve_install_dir "$install_path") || exit $?

sync_lib_if_behind "$PAYLOAD" "$abs_install" "$SCRIPT_DIR/../.claude-plugin/plugin.json"
rc=$?

case $rc in
  0) print -- "  lib at $abs_install/lib is now current." ;;
  1) print -- "  lib at $abs_install/lib is already current — nothing to do." ;;
  2) ;;  # stderr note already emitted by sync_lib_if_behind
esac

# Refresh the smoke-mutation gate for this consumer too (idempotent). Project
# root = the git root at/above the install dir, else the install dir's parent.
proj_root="${abs_install:h}"
_d="$abs_install"
while [[ -n "$_d" && "$_d" != "/" ]]; do
  [[ -d "$_d/.git" ]] && { proj_root="$_d"; break; }
  _d="${_d:h}"
done
install_mutation_gate_hook "$PAYLOAD" "$proj_root"

exit 0
