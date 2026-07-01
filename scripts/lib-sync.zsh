#!/usr/bin/env zsh
# lib-sync.zsh — shared "what the lib is and how to install it" helper.
#
# Sourced by both scaffolders (smoke-init.zsh, smoke-add.zsh) so the install
# block lives in exactly one place and the two paths cannot drift.
#
# Public functions:
#   skill_version <plugin_json>            → echo the skill version
#   sync_lib <payload> <abs_install> <ver> → install shared lib + stamp version
#   version_lt <a> <b>                     → return 0 iff a < b (semver compare)

# Echo the skill version. Reads .version via jq when jq + the file are present;
# otherwise echoes 0.0.1 (mirrors the historical init fallback exactly).
skill_version() {
  local plugin_json="$1"
  if [[ -f "$plugin_json" ]] && command -v jq >/dev/null 2>&1; then
    jq -r .version "$plugin_json"
  else
    print -- "0.0.1"
  fi
}

# Install the shared lib + AUTHORING_GUIDE.md into <abs_install>, then stamp
# lib/.skill-version with <version>. Full copy — additive-safe, keeps the set
# consistent. Clobbers any local edits (lib is skill-owned).
sync_lib() {
  local payload="$1" abs_install="$2" version="$3"
  mkdir -p "$abs_install/lib"
  cp "$payload/lib/env.zsh"        "$abs_install/lib/"
  cp "$payload/lib/log.zsh"        "$abs_install/lib/"
  cp "$payload/lib/control.zsh"    "$abs_install/lib/"
  cp "$payload/lib/term-a.zsh"     "$abs_install/lib/"
  cp "$payload/lib/pause.zsh"      "$abs_install/lib/"
  cp "$payload/lib/history.zsh"    "$abs_install/lib/"
  cp "$payload/lib/README.md"      "$abs_install/lib/"
  cp "$payload/AUTHORING_GUIDE.md" "$abs_install/"
  print -- "$version" > "$abs_install/lib/.skill-version"
}

# project_root_of <start-dir> — echo the consumer project root: the git root at
# or above <start-dir>, else <start-dir> itself. The mutation-gate hook + its
# settings.json entry live under <root>/.claude.
project_root_of() {
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -d "$d/.git" ]] && { print -r -- "$d"; return 0; }
    d="${d:h}"
  done
  print -r -- "$1"
}

# install_mutation_gate_hook <payload> <project_root>
#
# Install the smoke-mutation-gate PreToolUse hook into the CONSUMER project so an
# agent cannot `container/docker exec`, `kill`/`pkill`, or `rm` a LIVE smoke run's
# containers out from under it. Two parts, both under <project_root>/.claude:
#   1. copy payload/hooks/smoke-active-gate.sh → .claude/hooks/ (chmod +x)
#   2. merge a PreToolUse/Bash hook entry into .claude/settings.json — idempotent
#      (skip if already present) and non-clobbering (append, never replace other
#      hooks). Requires jq for the merge; without jq, copies the script and prints
#      the manual settings snippet.
# The hook goes live only after a `/hooks` reload or a Claude Code restart.
install_mutation_gate_hook() {
  local payload="$1" proj="$2"
  local hooks_dir="$proj/.claude/hooks"
  local settings="$proj/.claude/settings.json"
  # $CLAUDE_PROJECT_DIR is a literal placeholder Claude Code expands at hook time
  # — it must NOT expand here, so single quotes are intentional.
  # shellcheck disable=SC2016
  local gatecmd='"$CLAUDE_PROJECT_DIR/.claude/hooks/smoke-active-gate.sh"'

  mkdir -p "$hooks_dir"
  command cp -f "$payload/hooks/smoke-active-gate.sh" "$hooks_dir/"
  chmod +x "$hooks_dir/smoke-active-gate.sh"

  if ! command -v jq >/dev/null 2>&1; then
    print -u2 "  note: jq not found — copied smoke-active-gate.sh but did NOT wire settings.json."
    print -u2 "  Add this PreToolUse hook to $settings by hand:"
    print -u2 "    {\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":$gatecmd}]}"
    return 1
  fi

  local current tmp
  # Read the existing settings (or {} when absent/empty) into a var so jq
  # consumes a single well-formed object on stdin — no process substitution.
  current="$(cat "$settings" 2>/dev/null)"
  [[ -z "$current" ]] && current='{}'
  # Guard against an invalid existing settings.json — jq would fail the merge
  # and we'd silently leave it unwired. Name the cause instead.
  if ! printf '%s' "$current" | jq empty >/dev/null 2>&1; then
    print -u2 "  WARNING: $settings is not valid JSON — copied the hook but skipped wiring. Fix the file, then re-run /smoke-sync."
    return 1
  fi
  tmp="$(mktemp)"
  # Add the entry only if no existing PreToolUse hook already points at
  # smoke-active-gate.sh (idempotent); append, never replace other hooks.
  if printf '%s' "$current" | jq --arg gatecmd "$gatecmd" '
        .hooks //= {}
        | .hooks.PreToolUse //= []
        | if any(.hooks.PreToolUse[]?; (.hooks[]?.command // "") | contains("smoke-active-gate.sh"))
          then .
          else .hooks.PreToolUse += [{matcher:"Bash", hooks:[{type:"command", command:$gatecmd}]}]
          end
      ' > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && command mv -f "$tmp" "$settings"; then
    print -- "  wired smoke-mutation gate into .claude/settings.json (reload /hooks or restart to activate)"
  else
    rm -f "$tmp"
    print -u2 "  WARNING: failed to merge settings.json; copied the hook but wiring skipped. Add the PreToolUse/Bash entry by hand."
    return 1
  fi
}

# resolve_install_dir <install_path>   (install_path may be empty)
#
# Resolve the install dir (the directory holding .smokerc) the same way both
# scaffolders do, WITHOUT scaffolding anything:
#   - explicit <install_path> (relative to $PWD or absolute) → require .smokerc
#   - empty → walk up from $PWD for .smokerc (boundary: .git or $HOME), then
#     fall back to <git-root>/docs/superpowers/smoke-tests/.smokerc
# Echoes the absolute install dir on stdout and returns 0 on success; prints an
# ERROR to stderr and returns 2 on failure.
resolve_install_dir() {
  local install_path="$1"
  local default_rel="docs/superpowers/smoke-tests"
  local abs_install=""

  if [[ -n "$install_path" ]]; then
    case "$install_path" in
      /*) abs_install="$install_path" ;;
      *)  abs_install="$PWD/$install_path" ;;
    esac
    if [[ ! -f "$abs_install/.smokerc" ]]; then
      print -u2 "ERROR: $abs_install/.smokerc not found; run /smoke-init --install-path $install_path first"
      return 2
    fi
    print -r -- "$abs_install"
    return 0
  fi

  local d="$PWD" halted_at=""
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.smokerc" ]]; then
      print -r -- "$d"
      return 0
    fi
    if [[ -d "$d/.git" || "$d" == "$HOME" ]]; then
      halted_at="$d"
      break
    fi
    d="${d:h}"
  done
  if [[ -n "$halted_at" && -d "$halted_at/.git" ]]; then
    local candidate="$halted_at/$default_rel"
    if [[ -f "$candidate/.smokerc" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  fi
  print -u2 "ERROR: no .smokerc found from $PWD upward${halted_at:+ (stopped at $halted_at)}; run /smoke-init first, or pass --install-path <path>"
  return 2
}

# sync_lib_if_behind <payload> <abs_install> <plugin_json>
#
# Version-gated lib sync, factored out so smoke-add and smoke-sync share one
# decision. Re-copies the shared lib only when the installed stamp is behind the
# skill; never downgrades. Returns:
#   0  synced (installed < skill) — prints "  synced shared lib X → Y"
#   1  already current (installed == skill) — prints nothing
#   2  installed newer than skill — prints a stderr note, leaves lib as-is
sync_lib_if_behind() {
  local payload="$1" abs_install="$2" plugin_json="$3"
  local current installed
  current=$(skill_version "$plugin_json")
  installed=$(cat "$abs_install/lib/.skill-version" 2>/dev/null || echo 0.0.0)
  if version_lt "$installed" "$current"; then
    sync_lib "$payload" "$abs_install" "$current"
    print -- "  synced shared lib $installed → $current"
    return 0
  elif version_lt "$current" "$installed"; then
    print -u2 "  note: installed lib ($installed) newer than skill ($current); leaving as-is"
    return 2
  fi
  return 1
}

# Return 0 (true) iff version $1 < $2 by field-wise base-10 semver compare.
# Shorter version is zero-padded; non-numeric fields treated as 0 (defensive —
# skill versions are always numeric X.Y.Z). 10# forces base-10 so leading-zero
# fields are not read as octal.
version_lt() {
  local a="$1" b="$2"
  local -a af bf
  af=("${(@s:.:)a}")
  bf=("${(@s:.:)b}")
  local n=$(( ${#af} > ${#bf} ? ${#af} : ${#bf} ))
  local i fa fb
  for (( i = 1; i <= n; i++ )); do
    fa="${af[i]:-0}"; fb="${bf[i]:-0}"
    [[ "$fa" =~ ^[0-9]+$ ]] || fa=0
    [[ "$fb" =~ ^[0-9]+$ ]] || fb=0
    (( 10#$fa < 10#$fb )) && return 0
    (( 10#$fa > 10#$fb )) && return 1
  done
  return 1
}
