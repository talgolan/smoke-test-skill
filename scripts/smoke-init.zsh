#!/usr/bin/env zsh
# /smoke-init scaffold script.
#
# Usage:
#   smoke-init.zsh --install-path <path> --topic <name> [--force]
#                  [--non-interactive --sut-bin <p> --sut-repo <p> --build-cmd <cmd>]
#
# Default --install-path: docs/superpowers/smoke-tests
# Resolved relative to $PWD.

set -u
emulate -L zsh

SCRIPT_DIR="${0:A:h}"
PAYLOAD="$(cd "$SCRIPT_DIR/.." && pwd)/payload"
source "$SCRIPT_DIR/lib-sync.zsh"

install_path="docs/superpowers/smoke-tests"
topic=""
force=false
non_interactive=false
sut_bin=""
sut_repo=""
build_cmd=""
preflight_tools=""

while (( $# > 0 )); do
  case "$1" in
    --install-path) install_path="$2"; shift 2 ;;
    --topic)        topic="$2"; shift 2 ;;
    --force)        force=true; shift ;;
    --non-interactive) non_interactive=true; shift ;;
    --sut-bin)      sut_bin="$2"; shift 2 ;;
    --sut-repo)     sut_repo="$2"; shift 2 ;;
    --build-cmd)    build_cmd="$2"; shift 2 ;;
    --preflight)    preflight_tools="$2"; shift 2 ;;
    *) print -u2 "ERROR: unknown arg: $1"; exit 2 ;;
  esac
done

abs_install="$PWD/$install_path"

# Refuse if install dir exists and is non-empty (unless --force).
if [[ -d "$abs_install" ]] && [[ -n "$(ls -A "$abs_install" 2>/dev/null)" ]]; then
  if ! $force; then
    print -u2 "ERROR: $abs_install not empty; use --force or pick different --install-path"
    exit 2
  fi
  ts=$(date +%Y%m%d-%H%M%S)
  backup="${abs_install}.backup-${ts}"
  print -- "  backing up existing tree to $backup"
  mkdir -p "$backup"
  for f in "$abs_install/lib" "$abs_install/AUTHORING_GUIDE.md" "$abs_install/.smokerc"; do
    [[ -e "$f" ]] && mv "$f" "$backup/"
  done
fi

# Topic prompt
if [[ -z "$topic" ]]; then
  if $non_interactive; then
    print -u2 "ERROR: --topic required in --non-interactive mode"
    exit 2
  fi
  print -n -- "Topic name (e.g. ssh-access, port-exposure): "
  read -r topic </dev/tty
fi
[[ -n "$topic" ]] || { print -u2 "ERROR: topic empty"; exit 2; }

# Install shared lib + AUTHORING_GUIDE.md + version stamp (shared with smoke-add).
plugin_json="$SCRIPT_DIR/../.claude-plugin/plugin.json"
sync_lib "$PAYLOAD" "$abs_install" "$(skill_version "$plugin_json")"

# .smokerc generation
if $non_interactive; then
  : "${sut_bin:?--sut-bin required in --non-interactive}"
  : "${sut_repo:?--sut-repo required in --non-interactive}"
  : "${build_cmd:?--build-cmd required in --non-interactive}"
else
  print -- "Configure .smokerc:"
  if [[ -z "$sut_bin" ]]; then
    print -n -- "  SUT_BIN (absolute path to binary): "
    read -r sut_bin </dev/tty
  fi
  if [[ -z "$sut_repo" ]]; then
    print -n -- "  SUT_REPO (absolute path to repo root): "
    read -r sut_repo </dev/tty
  fi
  if [[ -z "$build_cmd" ]]; then
    print -n -- "  BUILD_CMD (run from \$SUT_REPO to build): "
    read -r build_cmd </dev/tty
  fi
fi

[[ -z "$preflight_tools" ]] && preflight_tools="jq lsof tmux"

cat > "$abs_install/.smokerc" <<EOF
# .smokerc — sourced by every run.zsh
# Required
SUT_BIN="$sut_bin"
SUT_REPO="$sut_repo"
BUILD_CMD="$build_cmd"

# Optional (defaults shown)
SMOKE_ROOT="\${SMOKE_ROOT:-\$HOME/smoke}"
PREFLIGHT_TOOLS=($preflight_tools)
BUDGET_DEFAULT=30
RUN_LOG_KEEP=3

# Hooks (optional zsh functions)
# pre_run()   { :; }
# post_run()  { :; }
# reset_cmd() { :; }
EOF

# Delegate first-runner scaffold to smoke-add.zsh
"$SCRIPT_DIR/smoke-add.zsh" --install-path "$install_path" --topic "$topic" --from-init || exit $?

print -- ""
print -- "Done. Review and commit:"
print -- "  git add $install_path"
print -- "  git commit -m 'feat(smoke): scaffold smoke-test framework'"
print -- ""
print -- "Run the first runner:"
print -- "  $install_path/$topic/run.zsh --list"
