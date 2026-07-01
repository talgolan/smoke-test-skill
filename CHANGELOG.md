# Changelog

## 0.8.0

Ported from the itb project's ahead-of-source smoke framework (2026-07-01).

### ⚠️ Behavior change

- **Preserve-on-failure is now the DEFAULT.** A FAILED section keeps its
  diagnostic state (live container, isolated `$HOME`, capture files) so the root
  cause can be read from the real artifacts. A PASSED section always tears down.
  Set `SMOKE_KEEP_ON_FAIL=0` to force teardown-on-failure. **CI / unattended
  sweeps should set `SMOKE_KEEP_ON_FAIL=0`** or leftover containers will
  accumulate. Existing runners that never set the var will START preserving on
  failure after a `/smoke-sync`.

### Added

- **Smoke-mutation gate.** `/smoke-init` (and `/smoke-sync`) install a
  `PreToolUse` Bash hook (`smoke-active-gate.sh`) into the consumer's `.claude/`
  that, while a smoke run is active, blocks `container/docker exec`,
  `kill`/`pkill`, and `container delete`/`docker rm` — forcing read-only
  inspection so an agent can't contaminate a live run. Sentinel path defaults to
  `$HOME/.smoke-run-active`; override with `SMOKE_SENTINEL_FILE`
  (`run.zsh` and the hook read the same var). `SMOKE_GATE_OVERRIDE=1` escapes.
  Goes live after a `/hooks` reload or restart.
- **`term_a_wait_ready "<slug>" "<probe>" [timeout]`** — fail-fast readiness
  wait. Runs the probe each tick; if the launching term-A session dies before
  readiness, dumps the pane tail (the SUT's real error) and returns 2 instead of
  hanging to the timeout. `term_a_launch_died "<slug>"` is the exposed primitive.

### Fixed

- **`term_a_capture` now reads the pipe-log after the session exits.** On a fast
  abort the tmux session is already gone; the helper now falls back to tailing
  `logs/<NN>-<slug>-pane.log` so the real error survives instead of logging only
  "session not present".
