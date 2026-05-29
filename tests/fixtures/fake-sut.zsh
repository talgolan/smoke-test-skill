#!/usr/bin/env zsh
# Fake SUT for tests. Prints version on --version, status on `status`.
case "$1" in
  --version) echo "fake-sut 1.0.0"; exit 0 ;;
  status)    echo "running"; exit 0 ;;
  --hang)    while true; do sleep 0.1; done ;;
  *)         echo "fake-sut: unknown command: $*" >&2; exit 1 ;;
esac
