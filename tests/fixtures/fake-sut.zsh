#!/usr/bin/env zsh
# Fake SUT for tests. Prints version on --version, status on `status`.
#
# `wizard <outfile>` is an interactive first-run wizard used to exercise the
# term_a_send / term_a_answer primitives: it asks two prompts, then writes a
# JSON line to <outfile> with the answers and a `completedInit:true` sentinel
# (written LAST, so a test can wait for genuine completion rather than the
# first artifact).
case "$1" in
  --version) echo "fake-sut 1.0.0"; exit 0 ;;
  status)    echo "running"; exit 0 ;;
  --hang)    while true; do sleep 0.1; done ;;
  wizard)
    outfile="$2"
    printf "Backend (docker/container) [docker]: "
    read -r backend
    [[ -z "$backend" ]] && backend="docker"
    printf "Enter harness ids: "
    read -r harnesses
    print -r -- "{\"backend\":\"$backend\",\"harnesses\":\"$harnesses\",\"completedInit\":true}" > "$outfile"
    echo "init complete"
    exit 0
    ;;
  *)         echo "fake-sut: unknown command: $*" >&2; exit 1 ;;
esac
