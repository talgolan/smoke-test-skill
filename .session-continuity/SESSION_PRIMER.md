# Session Primer — smoke-test-skill

You are picking up work on smoke-test-skill from a previous session.
This file is the shortest path to productive context. Read it in order.

## Ground rules (how to work here)

1. Don't assume. Don't hide confusion. Surface tradeoffs.
2. Minimum code that solves the problem. Nothing speculative.
3. Touch only what you must. Clean up only your own mess.
4. Define success criteria. Loop until verified.

## First things first (read these before touching anything)

1. **`README.md`** at the repo root — what/why/how/tradeoffs/non-goals
   for the whole skill. Comprehensive; read it before changing the
   surface.
2. **`.session-continuity/LEARNINGS.md`** — graveyard of subtle bugs,
   grouped by layer. If you hit something weird, grep this file first.
3. **`payload/AUTHORING_GUIDE.md`** — the rule catalog the skill ships
   into target projects. Every rule has an originating failure
   attached. When changing payload behavior, update the guide too.

## Repo layout

This is a standalone Claude Code plugin (TypeScript test harness +
zsh payload). Nothing is monorepo-shaped; one package, one repo.

```
smoke-test-skill/
├── commands/                  # slash-command tomls (smoke-init, smoke-add)
├── scripts/                   # zsh scaffolders the slash commands invoke
├── payload/                   # files copied into target projects
│   ├── lib/                   # env.zsh, log.zsh, term-a.zsh, pause.zsh
│   ├── template/              # run.zsh + steps/01-example.zsh template
│   └── AUTHORING_GUIDE.md
├── skills/smoke-test/         # skill metadata
├── tests/                     # Bun tests (init/add/runner/shellcheck)
│   └── fixtures/              # fake-sut.zsh + fixture configs
├── package.json               # Bun project (devDeps: @types/bun)
└── README.md
```

The skill **scaffolds** files into target projects; it does not proxy
them at runtime. After `/smoke-init`, the target repo owns its
`lib/` + `AUTHORING_GUIDE.md` + runners. Bug fixes here don't
auto-propagate — `/smoke-init --force` overwrites with a sibling
backup.

## Working directory

```
/home/assistant/smoke-test-skill
```

Edit source here. The "target project" in test fixtures lives under
`/tmp/...` and is created/destroyed by Bun tests; never edit there.

## The packages / modules

| Package | Purpose | Notes |
|---|---|---|
| `commands/` | Slash-command tomls | `/smoke-init`, `/smoke-add` |
| `scripts/` | zsh scaffolders | invoked by the slash commands |
| `payload/lib/` | zsh primitives shipped to targets | `verify`, `run`, `log`, `pass`, `fail`, `wait_for_port`, tmux helpers |
| `payload/template/` | Runner template | `run.zsh` controller + `steps/01-example.zsh` |
| `tests/` | Bun test suite | scaffolder + runner + shellcheck gates |

## Test expectations — these must stay green

```
bun test   # 54 pass / 0 fail  (53 pass + 2 flaky history #3/#4 timeouts; see Outstanding #1)
```

9 of the 50 tests run `shellcheck` against shipped zsh files. They
require `shellcheck` on `$PATH` — without it they fail
environmentally (Ubuntu: `sudo apt-get install shellcheck`; macOS:
`brew install shellcheck`). If non-shellcheck tests regress,
something is broken — fix before adding new work.

Keep the counts honest — update on every commit that touches test
code. See "Primer maintenance" at the end of this file.

## End-to-end check (real integration)

Manual sandbox integration is documented in `tests/manual-run-notes.md`:
clone-into-sandbox → `/smoke-init` → run scaffolded runner → verify
PASS summary. Last manual run passed (commit `6328141`).

```bash
bun test                                   # automated
cat tests/manual-run-notes.md              # latest manual integration receipt
```

No external services, no credentials, no costs.

## Current state

- **v0.5.0 — lib-sync (itb #21) on `feat/21-lib-sync`.** `/smoke-add` never
  re-copied the shared `lib/` — only `/smoke-init` did. So a newer `run.zsh`
  sourcing a helper the frozen lib lacked (e.g. `control.zsh`, v0.4.0) died at
  `--list`. Fix = version-gated sync. New `scripts/lib-sync.zsh` (single source
  of truth, 3 fns: `skill_version` / `sync_lib` / `version_lt`). Both
  scaffolders source it: `smoke-init` calls `sync_lib` in place of its inlined
  8-`cp` block (refactor, behavior unchanged); `smoke-add` compares installed
  `lib/.skill-version` to `plugin.json` version and re-copies when behind
  (missing stamp → `0.0.0` → sync; installed > skill → stderr note, never
  downgrade). `version_lt` is pure-zsh field-wise semver compare with `10#`
  base-10 forcing (octal trap). `tests/add-lib-sync.test.ts` +4 (all PASS);
  shellcheck FILES +`lib-sync.zsh` with SC2296 disabled (zsh `${(@s:.:)x}`
  split flag). `plugin.json` 0.4.0 → 0.5.0 so downstream detects the skew and
  pulls lib-sync itself. tsc clean. Spec:
  `docs/superpowers/specs/2026-06-04-smoke-add-lib-sync-design.md`.
- **v0.4.0 on `feat/v0.4.0-evidence-preservation`.** Backports the 5
  improvements the itb sf-integration-smoke work surfaced (itb LEARNINGS
  #118 + 5 serial §3 failures). New `payload/lib/control.zsh`:
  1. **`smoke_keep_on_fail`** + `keep_on_fail_notice` — guard teardown so a
     failed run leaves diagnostic state alive (`SMOKE_KEEP_ON_FAIL=1` AND
     `FAIL_COUNT>0`; FAIL_COUNT is live in the per-section sub-shell). New
     AUTHORING_GUIDE §10 "Preserving evidence on failure".
  2. **`poll_until <success> <failure> <timeout> [interval]`** — poll BOTH
     signals (rc 0=success / 2=failure / 1=timeout) so a fast failure aborts
     early instead of burning the budget. Guide hard-rule #14.
  3. **eval-host-expansion rule** — `verify`/`poll_until` `eval` their string
     HOST-side, so `$HOME` inside an inner `docker exec` expands to the host
     home. Use literal container paths. Guide hard-rule #15 + grep-gate #8.
  4. **cold-build ready-wait** — size the wait vs `BUDGET_SECONDS`, not warm
     time. Guide hard-rule #16.
  5. **secret handling** — new guide §13 "Testing against a real authenticated
     service" (skip-when-absent, env-var-only crossing, redact-before-log,
     read-only assertion).
  Wiring: control.zsh cp'd in `scripts/smoke-init.zsh`, sourced ×2 in
  `payload/template/run.zsh` (top-level + alarm sub-shell), shellcheck FILES,
  lib/README row. `tests/control.test.ts` +9. Tests 41 → 50, `bun test` 50/0,
  shellcheck green, `tsc --noEmit` clean. `plugin.json` 0.3.0 → 0.4.0. NOTE:
  itb's `docs/superpowers/smoke-tests/lib/` is a v0.3.0 snapshot — re-pull to
  get the new helpers.
- **v0.3.0 shipped on `main` (commit `a20f7a1`, PR #3 squash-merged).**
  Topic-helper auto-wiring (`run.zsh` sources `<topic>/lib/*.zsh` in both
  scopes), interactive-SUT primitives (`term_a_send`/`term_a_answer` + guide
  §12), global-state hermeticity rule (guide #13). Tests 35 → 40/41.
- v0.2.0 shipped on `main` (commit `29e2eb7`, PR #2 squash-merged).
  README comprehensive; manual sandbox integration test passed.
- v0.1.0 shipped earlier on `main` (commit `ddec1d0`). PR #1
  (duration-history spec) merged. Two follow-up fixes landed for
  plugin marketplace install: `source` schema and `author` schema.
  See LEARNINGS #1, #2.
- Walk-up boundary UX gap **resolved** in v0.1.0: smoke-add accepts
  `--install-path <path>` AND falls back to
  `<git-root>/docs/superpowers/smoke-tests/.smokerc` when walk-up halts
  at `.git`.
- **Duration history + adaptive runs** implemented (spec
  `2026-05-29-duration-history-design.md`). New
  `payload/lib/history.zsh` (5 public fns: stats / poll / budget /
  outlier / append / cap), wired into `payload/template/run.zsh`:
  pre-run banner with p50/p95/poll/budget per section, drift WARN
  when p95 ≥ budget (count ≥ 5), per-section history append +
  cap-after-summary, outlier marker (`⚠ Nx median`) on PASS rows.
  `<topic>/.history.jsonl` is committed by default. 8 new history
  tests + runner-smoke assertion of banner.

**Current `git log --oneline -5` (HEAD, pre-this-commit per LEARNINGS #3):**

```
bbad99a feat: version-gated lib sync in smoke-add (#21) (#5)
21f7117 docs(spec): version-gated lib sync in smoke-add (#21)
a033baf docs(primer): sync HEAD log block to post-#4 main (v0.4.0)
501fea8 feat: evidence-preservation + dual-signal polling (v0.4.0) (#4)
a20f7a1 feat: topic-helper auto-wiring + interactive-SUT primitives (v0.3.0) (#3)
```

Regenerate this block whenever you commit — see "Primer maintenance"
below.

## Outstanding items (explicitly deferred — not bugs, decisions)

_None at HEAD._

1. ~~**Flaky `history #3`/`#4` (5005ms timeouts).**~~ Closed 2026-06-08 (PR
   #6). Genuine borderline timeout: the history step just `sleep`s (no tmux),
   and a 4.4s test under `bun test` parallel CPU load brushed the 5000ms
   default per-test timeout. Fix = `const TIMEOUT = 30_000` passed as the 3rd
   arg to all 8 subprocess tests in `tests/history.test.ts`. Verified 3× clean
   in-sandbox + 2× clean out-of-sandbox. NOTE: a parallel investigation of
   `term_a_answer` (also failing ~5005ms) found it was a **sandbox artifact**,
   not a flake — the Bash-tool seatbelt blocks tmux's unix socket
   (`Operation not permitted`); it passes in 2.95s outside the sandbox. No
   change needed there. Lesson: reproduce a Bash-sandbox failure OUTSIDE the
   sandbox before treating it as a code/test bug.

Previous outstanding #1 (walk-up boundary UX gap) resolved — see "Current state".

## Workflow conventions

- **Conventional Commits** — prefixes used so far: `docs`, `test`,
  `chore`, `fix`, `feat`. Subject ≤ ~70 chars.
- **`bun test` must stay green** — non-shellcheck tests are the gate.
- **`shellcheck` clean** on all shipped zsh files (`payload/`,
  `scripts/`) — enforced by `tests/shellcheck.test.ts` when the binary
  is available.
- **Read `.session-continuity/LEARNINGS.md` before blaming the code.**
  Half the bugs you hit are already documented there.
- **Commit messages end with:**
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```

## Where to look for what

| Question | File |
|---|---|
| "Why does X work this way?" | `.session-continuity/LEARNINGS.md`, `payload/AUTHORING_GUIDE.md`, README |
| "What did the last session do?" | `git log`, `tests/manual-run-notes.md` |
| "How do I configure a target project?" | `payload/template/.smokerc` (after scaffold) |
| "How do I test Z?" | "Test expectations" section above |
| "What is the public surface?" | `commands/*.toml`, README "Use" section |
| "Who is the user?" | Global `~/.claude/CLAUDE.md` for cross-project context |

## If you get stuck

In order of cost:

1. Grep `.session-continuity/LEARNINGS.md` for your symptom.
2. Grep `payload/AUTHORING_GUIDE.md` — many traps live there with
   originating failures attached.
3. Re-read the failing test fixture under `tests/fixtures/`; the
   fake-sut harness is the cheapest way to reproduce runner behavior.
4. Ask the user.

## Primer maintenance (your responsibility)

Refresh this file **alongside substantive commits**, not as a standalone
follow-up. Two sections are the usual targets:

- **Current state** — regenerate the `git log --oneline -5` block so
  a future session sees the real latest commits.
- **Outstanding items** — if you finished one, remove it. If a code
  review flagged a new follow-up, add it.

**When to update** — stage primer edits in the same commit as the
real change that made them necessary.

**When NOT to update** — do NOT commit the primer by itself just to
record the previous primer refresh. Treat primer-only commits as a
one-shot catch-up, not a habit.

**Never stage `{{...}}` placeholders.** The log block can't include
the SHA of the commit shipping it (chicken-and-egg). Default: snapshot
the current `git log` pre-commit and accept that the primer is current
as of HEAD~1 once the commit lands. The next substantive primer
refresh catches up. Run
`grep -n '{{' .session-continuity/SESSION_PRIMER.md` before `git add`
— must return nothing. See LEARNINGS #3.

When a bug takes more than 15 minutes to diagnose, update
`.session-continuity/LEARNINGS.md` too (see that file's footer for
numbering rules).
