# Shared smoke-test library

Reusable zsh helpers sourced by every runner's `run.zsh`.

## Files

| File         | Purpose |
|--------------|---------|
| `env.zsh`    | Validates `.smokerc` (`SUT_BIN`, `SUT_REPO`, `BUILD_CMD`); sets `SMOKE_ROOT`; provides `wait_for_port`. Refuses to run if `$SUT_BIN` not executable. |
| `log.zsh`    | `log` / `info` / `warn` / `err` / `sect` plus `pass` / `fail` / `skip` / `verify` / `run` helpers. Tees everything to `$RUN_LOG` and stdout. |
| `term-a.zsh` | tmux detached-session spawn / pane-grep / capture / close. Use for any step that needs a real TTY (`docker run -it`, anything that calls `stty`). |
| `pause.zsh`  | `pause "<headline>" "<body>"` for operator-action steps; `confirm "<question>"` y/n prompt. Both read from `/dev/tty`. |

## How a runner sources these

```zsh
# In your <topic>/run.zsh, after sourcing .smokerc:
source "$SMOKE_LIB/log.zsh"
source "$SMOKE_LIB/env.zsh"
source "$SMOKE_LIB/term-a.zsh"
source "$SMOKE_LIB/pause.zsh"
```

`$SMOKE_LIB` is resolved by `run.zsh` walking up from `${0:A:h}` until it finds the install dir's `.smokerc`, then descending into `lib/`.

## Per-section budget

`run.zsh` wraps each step in `perl -e 'alarm(N); exec @ARGV'`. Default 30 s. Sections that need more declare a per-step override:

```zsh
#!/usr/bin/env zsh
# BUDGET_SECONDS=120
# Reason: this section pulls a 200MB image on a cold cache.
```

`BUDGET_SECONDS=N` env var overrides globally; `BUDGET_SECONDS=0` disables enforcement (debugging only).

## Logging

Every command that goes through `verify` / `run` / `log` lands in `$RUN_LOG` (`logs/run-<timestamp>.log`) and stdout. Old logs auto-prune to last 3 (`RUN_LOG_KEEP=N` to override; 0 disables pruning).

`term-a.zsh` additionally pipes the tmux pane to `logs/<NN>-<slug>-pane.log` so spawned process output survives even if the tmux session dies in <1 s.

Per-section duration is reported in the summary table at the end of every run.

## Why tmux instead of `pbpaste|bash` or `osascript`

Steps that drive the SUT through `stty` or `docker run -it` need a real TTY. `pbpaste | bash` runs in a non-TTY sub-shell — TTY check fails. `osascript Terminal.app` works for the pty but introduces AppleScript escaping bugs and zombie windows on close.

`tmux new-session -d` gives a real pty, runs detached (no GUI), and `tmux kill-session` is a clean teardown. macOS + Linux portable.
