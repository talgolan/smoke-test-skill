# Shared smoke-test library

Reusable zsh helpers sourced by every runner's `run.zsh`.

## Files

| File         | Purpose |
|--------------|---------|
| `env.zsh`    | Validates `.smokerc` (`SUT_BIN`, `SUT_REPO`, `BUILD_CMD`); sets `SMOKE_ROOT`; provides `wait_for_port`. Refuses to run if `$SUT_BIN` not executable. |
| `log.zsh`    | `log` / `info` / `warn` / `err` / `sect` plus `pass` / `fail` / `skip` / `verify` / `run` helpers. Tees everything to `$RUN_LOG` and stdout. |
| `control.zsh` | `poll_until <success-cmd> <failure-cmd> <timeout> [interval]` (returns 0=success, 2=failure signal, 1=timeout — poll BOTH signals so a fast failure aborts early); `cap <seconds> <cmd>...` (hard per-command timeout — returns the command's real rc, or 124 if killed at the cap; the per-COMMAND analogue of run.zsh's per-SECTION budget, for hang-prone daemon/service calls); `smoke_keep_on_fail` (true when `SMOKE_KEEP_ON_FAIL` set AND section failed — guard teardown to preserve evidence); `keep_on_fail_notice <handle>...` (print live diagnostic handles). |
| `term-a.zsh` | tmux detached-session spawn / pane-grep / capture / close, plus `term_a_send` + `term_a_answer` for scripting an interactive SUT's prompts. Use for any step that needs a real TTY (`docker run -it`, anything that calls `stty`) or that must answer a SUT's own setup wizard. |
| `pause.zsh`  | `pause "<headline>" "<body>"` for operator-action steps; `confirm "<question>"` y/n prompt. Both read from `/dev/tty`. |
| `history.zsh` | Per-section duration history + adaptive recommendations. Public functions: `history_stats <file> <section>`, `history_recommend_poll <p95>`, `history_recommend_budget <p95>`, `history_is_outlier <duration> <p50>`, `history_append <file> <section> <duration> <result> <budget>`, `history_cap <file>`. Soft-fails on every disk error — never breaks a run. |

## How a runner sources these

```zsh
# In your <topic>/run.zsh, after sourcing .smokerc:
source "$SMOKE_LIB/log.zsh"
source "$SMOKE_LIB/env.zsh"
source "$SMOKE_LIB/control.zsh"
source "$SMOKE_LIB/term-a.zsh"
source "$SMOKE_LIB/pause.zsh"
source "$SMOKE_LIB/history.zsh"
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

Per-section duration is reported in the summary table at the end of every run, alongside an outlier marker (`⚠ Nx median`) when the run exceeds 2× the historical p50.

## Duration history

`run.zsh` writes one JSON line per (section, run) to `<topic>/.history.jsonl`. Capped to last 50 PASS + last 10 non-PASS rows per section; the file is committed by default. The pre-run banner reports `p50`, `p95`, current `budget`, and a recommended poll interval per section. A drift warning fires when `p95 ≥ budget` (suppressed below 5 PASS rows). All history operations soft-fail — a broken history layer is informative-only, never a gate.

## Why tmux instead of `pbpaste|bash` or `osascript`

Steps that drive the SUT through `stty` or `docker run -it` need a real TTY. `pbpaste | bash` runs in a non-TTY sub-shell — TTY check fails. `osascript Terminal.app` works for the pty but introduces AppleScript escaping bugs and zombie windows on close.

`tmux new-session -d` gives a real pty, runs detached (no GUI), and `tmux kill-session` is a clean teardown. macOS + Linux portable.
