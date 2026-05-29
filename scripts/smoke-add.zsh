#!/usr/bin/env zsh
# /smoke-add scaffold script.
#
# Usage:
#   smoke-add.zsh --topic <name>
#   smoke-add.zsh --install-path <path> --topic <name> --from-init
#
# When --from-init: install path is given (called by smoke-init.zsh
# before .smokerc exists in target). Skip the walk-up.
# Otherwise: walk up from $PWD until .smokerc found (boundary: .git or
# $HOME), then use that dir as the install path.

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

if $from_init; then
  abs_install="$PWD/$install_path"
else
  # Walk up from $PWD until .smokerc found, halting at .git or $HOME.
  d="$PWD"
  abs_install=""
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -f "$d/.smokerc" ]]; then
      abs_install="$d"
      break
    fi
    if [[ -d "$d/.git" || "$d" == "$HOME" ]]; then
      print -u2 "ERROR: no .smokerc found from $PWD upward (stopped at $d); run /smoke-init first"
      exit 2
    fi
    d="${d:h}"
  done
  [[ -n "$abs_install" ]] || { print -u2 "ERROR: no .smokerc found from $PWD upward; run /smoke-init first"; exit 2; }
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
