#!/usr/bin/env zsh
# Stub: full impl in Task 9. Just enough to satisfy init-fresh test.
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

abs_install="$PWD/$install_path"
topic_dir="$abs_install/$topic"

[[ -d "$topic_dir" ]] && {
  print -u2 "ERROR: $topic_dir exists; pick different topic"
  exit 2
}

mkdir -p "$topic_dir/steps"
cp "$PAYLOAD/template/run.zsh"            "$topic_dir/run.zsh"
cp "$PAYLOAD/template/README.md"          "$topic_dir/README.md"
cp "$PAYLOAD/template/steps/01-example.zsh" "$topic_dir/steps/01-example.zsh"

# Token substitution
for f in "$topic_dir/run.zsh" "$topic_dir/README.md" "$topic_dir/steps/01-example.zsh"; do
  sed -i '' "s/{{TOPIC}}/$topic/g" "$f"
done

# Verify no leftover tokens
if grep -l '{{TOPIC}}' "$topic_dir"/run.zsh "$topic_dir"/README.md "$topic_dir"/steps/*.zsh 2>/dev/null; then
  print -u2 "ERROR: token substitution incomplete"
  exit 2
fi

chmod +x "$topic_dir/run.zsh"

print -- "  scaffolded $topic_dir/"
