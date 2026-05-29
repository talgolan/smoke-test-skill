# Duration history & adaptive smoke runs — design

Status: draft, awaiting implementation plan
Branch: `feat/duration-history`
Author: Tal Golan + Claude

## Problem

Smoke runs that pull images, build the SUT, or wait on healthchecks can take minutes. Today the framework offers three numbers:

- A per-section budget (`# BUDGET_SECONDS=N`, default 30 s).
- The summary table's per-section duration after a run finishes.
- A blanket "poll every 30 s" guidance rule the operator/Claude follows during long runs.

Authors set budgets by gut feel; an operator polling a long run has no idea whether silence at 90 s is normal for a 100 s build or symptomatic of a hang at 20 s into a typically-12 s section. The same `30 s` poll cadence is wrong for both a 5-minute image pull (too noisy) and a 7-second healthcheck (too slow to catch a stall).

The framework already records per-section durations in `run-<ts>.log`, but logs are pruned (`RUN_LOG_KEEP=3`) and not aggregated. There is no durable history.

## Goals

1. Record per-section duration history across runs in a file the runner owns.
2. Surface "expected duration" stats (p50, p95) to the operator before each run.
3. Recommend a per-section liveness-poll interval based on history p95.
4. Warn when a section's historical p95 has overrun its current budget.
5. Annotate the post-run summary table when a section is a 2x outlier vs its historical median.
6. Make this work for new runners (no history → fall back to existing 30 s defaults).

## Non-goals

- No CSV/Prometheus/Grafana export. `cat .history.jsonl | jq` is enough.
- No cross-runner aggregate dashboard. Each `<topic>` keeps its own history.
- No automatic edits to `# BUDGET_SECONDS=` headers. Warn-only; author edits manually.
- No mid-run progress emission. Banner + summary annotation only.
- No clock-skew handling beyond ISO8601 timestamps. Multi-machine merges of the same `.history.jsonl` may produce out-of-order rows; harmless for stats.

## Architecture

```
<topic>/
├── run.zsh                  # writes history; prints banner; warns on drift; annotates summary
├── .history.jsonl           # NEW: append-only, capped per-section
└── steps/NN-*.zsh           # unchanged

payload/lib/
├── history.zsh              # NEW: stats + recommendations
└── ...                      # log.zsh / env.zsh / term-a.zsh / pause.zsh unchanged
```

No new processes. No new runtime dependencies. `history.zsh` uses `awk` + `grep` (zsh's own `printf` for JSON formatting on append) — no `jq` requirement (jq stays in `PREFLIGHT_TOOLS` for step-file assertions).

## Data shape — `.history.jsonl`

One JSON line per (section, run). Append-only. Cap rewrites in place after each run.

```jsonl
{"ts":"2026-05-29T10:01:00Z","section":"01-build","duration":47,"result":"PASS","budget":120}
{"ts":"2026-05-29T10:02:00Z","section":"02-up","duration":12,"result":"PASS","budget":30}
{"ts":"2026-05-29T11:15:23Z","section":"01-build","duration":118,"result":"TIMEOUT","budget":120}
```

| Field | Type | Notes |
|---|---|---|
| `ts` | string | ISO8601 UTC, second precision (`date -u +%Y-%m-%dT%H:%M:%SZ`). |
| `section` | string | `NN-slug`, matches `ALL_SECTIONS` entry. |
| `duration` | integer | Seconds the section ran (start_ts/end_ts already computed by `run.zsh`). |
| `result` | string | `PASS` / `FAIL` / `TIMEOUT` / `FAIL-missing`. |
| `budget` | integer | Budget in force this run (seconds). |

### Cap policy on write

After all sections finish in a given run, rewrite `.history.jsonl` keeping, **per section**:

- The last 50 entries with `result == "PASS"`.
- The last 10 entries with `result != "PASS"` (FAIL / TIMEOUT / FAIL-missing). Independent cap; failures do not count against the 50-PASS cap and recent failures are not evicted by old PASS history.

Implementation: `awk` group-by-section, take tail-50 of PASS rows and tail-10 of non-PASS rows independently, sort the union by ts ascending, write to `.history.jsonl.tmp`, `mv` over original.

### Concurrency

Runs are sequential per runner. No parallel `./run.zsh` is supported today. The cap-rewrite uses tmp-file `mv` for atomicity within the same runner directory.

### Git

`.history.jsonl` is committed. Diff per run is one appended line per section (rewrite when cap hits, ~50 lines per section steady state, ~5 KB per file). Authors who do not want history in repo opt out by `.gitignore`-ing `.history.jsonl` per-runner; documented in `<topic>/README.md`.

## Stats library — `payload/lib/history.zsh`

Generic helpers consumed by `run.zsh` and (potentially) by step files.

```
history_stats <history-file> <section>
  → emits to stdout: p50=<n> p95=<n> max=<n> count=<n>
  → count is the number of PASS rows for the section (0 if no data or no PASS)
  → p50/p95/max omitted from output line when count == 0

history_recommend_poll <p95>
  → echoes integer seconds: max(15, min(120, ceil(p95 / 4)))
  → fast section (p95=10) → 15 (floor)
  → typical section (p95=80) → 20
  → slow section (p95=600) → 120 (ceiling)

history_recommend_budget <p95>
  → echoes integer seconds: ceil(p95 * 1.5)

history_is_outlier <duration> <p50>
  → returns 0 (true) if p50 > 0 AND duration >= 2 * p50, else 1
  → emits no output

history_append <history-file> <section> <duration> <result> <budget>
  → appends one JSON line with ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  → soft-fails on disk write error (warn to stderr, return 0)

history_cap <history-file>
  → in-place cap-rewrite per the policy above
  → soft-fails (warn, return 0) — never breaks a run
```

All stats compute over `PASS` rows only. `FAIL`/`TIMEOUT` rows skew distribution for the wrong reason and are kept purely for diagnosis.

`history.zsh` is `set -u` clean and `shellcheck` clean (the existing `tests/shellcheck.test.ts` glob picks it up automatically).

## `run.zsh` changes

### Pre-run banner

Inserted between the existing `Smoke run` header and `Preflight`:

```
=== Expected durations (from .history.jsonl) ===
  01-build       p50=48s   p95=72s   budget=120s   poll every 18s
  02-up          p50=11s   p95=14s   budget=30s    poll every 15s
  03-drift       (no history)        budget=30s    poll every 15s
```

`(no history)` for sections with `count=0`. Column widths fixed; right-padded section names truncated at 14 chars (matches existing summary table width).

The "poll every Ns" column is informational. The skill rule consumes it; `run.zsh` itself does not change behavior based on it.

### Drift warning

Emitted under the duration table when `p95 >= budget` for any section:

```
WARN: section 01-build p95=72s ≥ current budget=60s.
      Consider raising: # BUDGET_SECONDS=108  (1.5 × p95)
```

Exact `108` = `history_recommend_budget(72)`. One line per affected section. Suppressed for sections with `count < 5` (insufficient data).

### Per-run history append

After each section completes, `run.zsh` calls `history_append` with the (section, duration, mapped-result, budget) it already computed. The mapped result follows `SECTION_RESULT[$section]`:

- `PASS` → `PASS`
- `FAIL (rc=N)` → `FAIL`
- `TIMEOUT (>Ns)` → `TIMEOUT`
- `FAIL-missing` → `FAIL-missing`

After the summary table prints, single `history_cap` pass.

### Summary annotation

For each PASS row in the summary, if `history_is_outlier $duration $p50` returns 0:

```
=== Summary ===
  01-build       PASS    120s   ⚠ 2.5x median (historical p50=48s)
  02-up          PASS     12s
  03-drift       FAIL    rc=1     8s
```

Marker only on `PASS`. `FAIL` / `TIMEOUT` rows already self-explain; outlier markers there are noise. Multiplier rendered to one decimal place (`%.1fx`).

### Failure modes

| Condition | Behavior |
|---|---|
| `.history.jsonl` missing | Treat as empty. Banner shows `(no history)` for all sections. First run creates the file. |
| `.history.jsonl` line missing required fields | `awk` skips line. Warn once on stderr. Run continues; stats compute over remaining valid lines. |
| Disk write failure on append | Warn to stderr. Run continues. Exit code unaffected (history is informative, not gating). |
| Cap rewrite fails (disk full / perms) | Warn. File remains in pre-cap state. Next run retries. |

History never gates a run. A failing history layer is a degraded-but-functional run, not a failure.

## Skill / docs changes

### `skills/smoke-test/SKILL.md`

Rule 6 rewritten:

> **Monitor long-running smoke runs at the printed interval.** `run.zsh` emits per-section poll intervals in its pre-run banner (computed from history p95). Tail `<topic>/logs/run-<latest>.log` at that cadence. Two consecutive empty polls AND no advancement past the section header = hung; kill (`pkill -f run.zsh`, `tmux kill-session -t <slug>` for any active term-a sessions) and investigate. New sections without history default to 15 s. Share the banner's expected-duration table with the user before running so both sides know what "normal" looks like.

### `payload/AUTHORING_GUIDE.md`

§6 (Budgets) — add subsection "Budget vs history":

> Once a section has 5+ PASS entries in `.history.jsonl`, set `# BUDGET_SECONDS` to roughly `1.5 × p95(history)`. `run.zsh`'s pre-run banner prints both numbers; its drift warning fires when `p95 >= budget`. Avoid the temptation to set the budget to `p95 + 10s` — sections occasionally take 2x median for legitimate reasons (cold cache, slow CI runner), and a tight budget produces flaky TIMEOUTs without surfacing real bugs.

§10 ("Operating a long run") — replace the fixed-30s polling guidance with:

> While a run is in flight, poll the structured log at the **per-section interval printed in `run.zsh`'s pre-run banner**. Sections without history poll at 15 s. If a tail at p95 + 30 s shows no progress and the section's p50 is well under that, kill the run rather than waiting out `BUDGET_SECONDS`. The budget is an upper bound, not a health check.

### `payload/lib/README.md`

Add row for `history.zsh` listing the five public functions.

## Tests (Bun)

New file `tests/history.test.ts`:

1. **Empty history.** First run with no `.history.jsonl` → file is created with one line per section, banner shows `(no history)` for all sections, no drift warning.
2. **Stats computed.** Seed `.history.jsonl` with 6 PASS entries for `01-example` at durations [10, 12, 11, 13, 9, 50] → banner row shows `p50=11 p95=50` (or close — assert with tolerance), summary stays clean (current run not an outlier vs p50=11 yet because the 50 is in history).
3. **Outlier annotation.** Seed history with p50=10. Mock the section to take 30s → summary shows `⚠ 3.0x median`.
4. **Drift warning.** Seed history with p95=80, run with `# BUDGET_SECONDS=60` → pre-run WARN line appears with recommended budget=120 (`ceil(80*1.5)`).
5. **Cap policy.** Write 100 PASS lines and 15 FAIL lines for `01-example` → after one more run, file contains the most recent 50 PASS lines plus the most recent 10 FAIL lines for `01-example`, plus 1 new entry from the current run. Older PASS and older FAIL entries are gone.
6. **Corrupt JSON line.** Write valid lines plus one malformed line → run completes successfully, stats compute over valid lines, stderr contains exactly one warn.
7. **Insufficient data.** Seed history with 4 PASS entries → drift warning suppressed even when p95 >= budget (count < 5).

Existing `tests/runner.test.ts` updated:

- Assert new banner section appears.
- Assert `.history.jsonl` is created/updated by every test that runs the runner.
- No regression in PASS/FAIL/TIMEOUT exit code semantics or the existing summary table.

`tests/shellcheck.test.ts` automatically covers `payload/lib/history.zsh` via existing globs.

## Rollout

This is a new file (`.history.jsonl`) appearing in target projects after they run `/smoke-init --force` or simply use the new `lib/`. Existing target projects continue to work without it (history layer fails open). No migration step.

The `lib/.skill-version` already encodes the lib version; bump on release so `/smoke-init --force` knows to overwrite. PR bumps `lib/.skill-version` and `package.json` together.

## Open questions

None at design time. Implementation plan should resolve:

1. Exact `awk` script for `history_cap` (single-pass group-by-section).
2. Banner column widths if a section name exceeds 14 chars (truncate vs wrap).
3. Whether to include `count` in the banner row (e.g. `p50=48 p95=72 (n=23)`); leaning yes for the first 5 runs, no after — to be decided in plan.
