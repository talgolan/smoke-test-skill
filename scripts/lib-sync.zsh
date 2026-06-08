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
