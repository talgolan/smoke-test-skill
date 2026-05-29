#!/usr/bin/env zsh
# /smoke-add scaffold script.
#
# Usage:
#   smoke-add.zsh --topic <name>
#   smoke-add.zsh --install-path <path> --topic <name>
#   smoke-add.zsh --install-path <path> --topic <name> --from-init
#
# Discovery order:
#   1. If --install-path given: use it directly (relative to $PWD).
#      With --from-init, skip the .smokerc-exists check (init creates
#      it after this script returns).
#   2. Otherwise walk up from $PWD until .smokerc found (boundary: .git
#      or $HOME).
#   3. If walk-up halts at .git, probe <git-root>/docs/superpowers/
#      smoke-tests/.smokerc as a default-path fallback.

set -u
emulate -L zsh

SCRIPT_DIR="${0:A:h}"
PAYLOAD="$(cd "$SCRIPT_DIR/.." && pwd)/payload"

install_path=""
topic=""
from_init=false

while (( $# > 0 )); do
  case "$1" in
    --install-path) install_path="$2"; shift 2 ;;
    --topic)        topic="$2"; shift 2 ;;
    --from-init)    from_init=true; shift ;;
    *) print -u2 "ERROR: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$topic" ]] || { print -u2 "ERROR: --topic required"; exit 2; }

DEFAULT_INSTALL_REL="docs/superpowers/smoke-tests"

if $from_init; then
  [[ -n "$install_path" ]] || { print -u2 "ERROR: --install-path required with --from-init"; exit 2; }
  abs_install="$PWD/$install_path"
elif [[ -n "$install_path" ]]; then
  # Explicit --install-path: resolve relative to $PWD, require .smokerc.
  case "$install_path" in
    /*) abs_install="$install_path" ;;
    *)  abs_install="$PWD/$install_path" ;;
  esac
  if [[ ! -f "$abs_install/.smokerc" ]]; then
    print -u2 "ERROR: $abs_install/.smokerc not found; run /smoke-init --install-path $install_path first"
    exit 2
  fi
else
  # Walk up from $PWD until .smokerc found, halting at .git or $HOME.
  d="$PWD"
  abs_install=""
  halted_at=""
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.smokerc" ]]; then
      abs_install="$d"
      break
    fi
    if [[ -d "$d/.git" || "$d" == "$HOME" ]]; then
      halted_at="$d"
      break
    fi
    d="${d:h}"
  done
  # Fallback: if halted at .git, probe <git-root>/<DEFAULT_INSTALL_REL>/.smokerc.
  if [[ -z "$abs_install" && -n "$halted_at" && -d "$halted_at/.git" ]]; then
    candidate="$halted_at/$DEFAULT_INSTALL_REL"
    if [[ -f "$candidate/.smokerc" ]]; then
      abs_install="$candidate"
    fi
  fi
  if [[ -z "$abs_install" ]]; then
    print -u2 "ERROR: no .smokerc found from $PWD upward${halted_at:+ (stopped at $halted_at)}; run /smoke-init first, or pass --install-path <path>"
    exit 2
  fi
fi

topic_dir="$abs_install/$topic"

[[ -d "$topic_dir" ]] && {
  print -u2 "ERROR: $topic_dir exists; pick different topic"
  exit 2
}

mkdir -p "$topic_dir/steps" "$topic_dir/logs"
cp "$PAYLOAD/template/run.zsh"              "$topic_dir/run.zsh"
cp "$PAYLOAD/template/README.md"            "$topic_dir/README.md"
cp "$PAYLOAD/template/steps/01-example.zsh" "$topic_dir/steps/01-example.zsh"

# Token substitution. macOS sed needs `-i ''`; GNU sed uses `-i`.
sedi() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

for f in "$topic_dir/run.zsh" "$topic_dir/README.md" "$topic_dir/steps/01-example.zsh"; do
  sedi "s/{{TOPIC}}/$topic/g" "$f"
done

# Verify no leftover tokens
leftover=$(grep -l '{{TOPIC}}' "$topic_dir/run.zsh" "$topic_dir/README.md" "$topic_dir/steps"/*.zsh 2>/dev/null)
if [[ -n "$leftover" ]]; then
  print -u2 "ERROR: token substitution incomplete: $leftover"
  exit 2
fi

chmod +x "$topic_dir/run.zsh"

print -- "  scaffolded $topic_dir/"
print -- ""
print -- "  next: $abs_install/$topic/run.zsh --list"
