# smoke-test-skill

A standalone Claude Code plugin that scaffolds an executable, opinionated smoke-test framework into any project.

Two slash commands, one config file, a shared zsh primitive library, and an authoring guide where every rule has a real failure attached.

---

## Why this exists

Smoke testing — driving a built binary end-to-end against the real environment (real Docker, real ports, real filesystem, real `stty`) — is fundamentally different from unit testing, and most projects either skip it or reinvent it badly.

This skill is a **packaged version of the smoke-test framework** that grew inside one project (a Docker-managed dev-container CLI) over months of real use. After ~20 manual smoke runs, four major iterations, and the same paste-corruption / sub-shell / cwd / drift bugs surfacing repeatedly, the framework crystallized into something worth extracting:

- A controller (`run.zsh`) that orchestrates **sections** with per-section budget enforcement.
- A shared library (`lib/`) of zsh primitives — `verify`, `run`, `log`, `pass`, `fail`, `wait_for_port`, plus tmux helpers for any step that needs a real TTY.
- An **authoring guide** that documents every trap the framework's authors hit, with the originating failure preserved alongside each rule.
- A **generic configuration surface** (`.smokerc`) so any project — Bun, Rust, Go, Node, Python — can plug in its own SUT binary, repo path, and build command.

This skill is, deliberately, **the skill we wish we'd had when we started.** Future-you (or a contributor in a new repo) doesn't relearn the bugs we already paid for.

---

## What problem it solves

### 1. Manual paste-and-run smoke tests degrade fast

The original framework was markdown files of fenced shell blocks the operator copy-pasted into a terminal. Symptoms:

- macOS Terminal flushes paste keystrokes faster than zsh's line editor consumes them — long pastes break (`EOFmkdir` joined, words concatenated, heredocs corrupted).
- Multi-line setup blocks half-run, smoke continues with broken state.
- "Edit `resources/X.conf` using your editor of choice" prose between fenced blocks gets bypassed; the mutation never lands; downstream verifications fail spuriously.
- Sub-shell `cd` doesn't persist (`pbpaste | bash` runs in a sub-shell), so step files using relative paths quietly target the wrong cwd.

This skill replaces all of that with **executable runners**: zsh files driven by a controller, sections in their own sub-shells with absolute paths and idempotent setup, no human in the paste loop.

### 2. Per-section budget enforcement

Smoke runs that hang are worse than smoke runs that fail. A test that loops forever holds CI hostage. Every section runs under `perl -e 'alarm(N); exec @ARGV'`; if it exceeds its budget (default 30 s, override per-step), it's killed and reported as `TIMEOUT` in the summary. The full run still completes; you find out about all failures on one pass.

### 3. Structured logging

Every primitive (`verify`, `run`, `log`, `pass`, `fail`) tees to a timestamped `$RUN_LOG` plus stdout. The summary table at the end shows pass/fail/timeout per section with durations. No `grep`'ing through unstructured output to find what broke.

For tmux-spawned processes (`docker run -it`-style steps), pane output also pipes to a per-section log file — so you can debug a process that died in <1 s, before tmux's session even reported.

### 4. Hard-won bug avoidance, codified

`AUTHORING_GUIDE.md` (shipped into every install) is the heart of the skill. Each "hard rule" has its origin attached. Sample rules:

- **Use `RUN_OUT` not `out` for caller captures.** `verify` declares `local out` internally; if a step file also uses `out=...`, it gets shadowed during `eval`. (Originating: a §6 conflict-detection check returned PASS even when `RUN_OUT=""` because `out` was empty.)
- **Stash outside `pdir`.** If a section stashes host state, the stash dir lives at `$pdir.stash` (sibling), not `$pdir/stash` (child). Otherwise `rm -rf $pdir` in Teardown destroys the stash. (Originating: a smoke run destroyed an operator's real `~/.claude/plugins/`.)
- **Drift / image-rebuild tests rebuild the SUT after editing source resources.** Compile-time-baked resources (Bun's `import ... with { type: "text" }`, Go's `embed`, Rust's `include_str!`) don't update when you edit the source file alone.

The grep gate at the bottom of the guide catches these mechanically before commit.

### 5. Generic by construction

`.smokerc` declares everything project-specific: `SUT_BIN`, `SUT_REPO`, `BUILD_CMD`, optional `PREFLIGHT_TOOLS`, optional hooks (`pre_run`, `post_run`, `reset_cmd`). The `lib/` and step files reference only those abstractions. The same harness drives a Bun-built CLI, a Rust binary, a Go server, or anything else — the framework doesn't care.

---

## How it works

### Two slash commands

- **`/smoke-init`** — scaffolds the framework into a target project (default install path: `docs/superpowers/smoke-tests/`). Interactive prompts collect `SUT_BIN`, `SUT_REPO`, `BUILD_CMD`. Also creates the first runner.
- **`/smoke-add <topic>`** — scaffolds an additional runner from the template, in an existing install.

### What lands in the target project

```
<install-path>/                     # default: docs/superpowers/smoke-tests/
├── .smokerc                        # SUT_BIN, SUT_REPO, BUILD_CMD, hooks
├── lib/
│   ├── env.zsh                     # validates .smokerc; provides wait_for_port
│   ├── log.zsh                     # log/info/warn/err/sect, pass/fail/skip, verify, run
│   ├── term-a.zsh                  # tmux pty helpers (term_a_start/wait_port/grep/close)
│   ├── pause.zsh                   # operator-action prompts (pause / confirm)
│   ├── README.md                   # primitives reference
│   └── .skill-version              # which skill version generated this lib/
├── AUTHORING_GUIDE.md              # rule catalog + grep gate
└── <topic>/                        # one runner
    ├── run.zsh                     # controller: sections, budgets, summary
    ├── steps/01-example.zsh        # opinionated template demonstrating the rules
    └── README.md
```

### How the runner finds its install dir

`run.zsh` walks up from `${0:A:h}` until it finds `.smokerc`, halting at the first `.git` directory (repo boundary) or at `$HOME`. This is deliberate:

- `.smokerc` is **project-local** and never fights an unrelated parent project's config.
- A monorepo can host multiple installs (one per sub-package) without crosstalk.
- The runner refuses with a clear error if no `.smokerc` is found within the boundary.

### Section lifecycle

Each section is a step file `steps/NN-<slug>.zsh`. The controller, for each section in `ALL_SECTIONS`:

1. Checks for a `# BUDGET_SECONDS=N` header (else uses `BUDGET_DEFAULT`, default 30).
2. Spawns a sub-shell wrapped by `perl -e 'alarm(N); exec'`.
3. Sources `lib/log.zsh`, `lib/env.zsh`, `lib/term-a.zsh`, `lib/pause.zsh`.
4. Sources the step file with `SECTION_SLUG` and `SECTION_NUM` exported.
5. Records duration + result (`PASS` / `FAIL (rc=N)` / `TIMEOUT (>Ns)` / `FAIL-missing`).

After all sections, summary table → optional `post_run` hook → exit follows section results (post_run is warn-only).

### Configuration

`.smokerc` is a zsh-sourced file with required keys (`SUT_BIN`, `SUT_REPO`, `BUILD_CMD`) and optional knobs (`SMOKE_ROOT`, `PREFLIGHT_TOOLS`, `BUDGET_DEFAULT`, `RUN_LOG_KEEP`). Hooks (`pre_run`, `post_run`, `reset_cmd`) are zsh functions; the runner calls them only if defined (`typeset -f` test) — runners must work without them.

`lib/env.zsh` validates that the required keys are both set AND non-empty, and that `$SUT_REPO` is a directory and `$SUT_BIN` is executable. On failure it prints `BUILD_CMD` so the operator knows how to rebuild.

---

## Design decisions and tradeoffs

### Files committed into target repo

The skill **scaffolds**, it doesn't proxy. After `/smoke-init`, the target repo owns its `lib/`, `AUTHORING_GUIDE.md`, `.smokerc`, and runners. They live in version control. CI / other developers / different machines all have the framework without needing the skill installed.

Tradeoff: bug fixes in the skill don't auto-propagate. Re-run `/smoke-init --force` to overwrite (with a sibling backup at `<path>.backup-<ts>/`) — preserves `.smokerc` and existing runners.

### tmux, not osascript or `pbpaste|bash`

Steps that drive the SUT through `stty` or `docker run -it` need a real TTY. `pbpaste | bash` runs in a non-TTY sub-shell — TTY check fails. `osascript Terminal.app` works for the pty but introduces AppleScript escaping bugs and zombie windows on close.

`tmux new-session -d` gives a real pty, runs detached (no GUI), and `tmux kill-session` is a clean teardown. macOS + Linux portable.

### zsh, not bash

The framework uses zsh-only features (`${0:A:h}` for absolute script-dir resolution, `${(l:2::0:)arg}` left-pad for section number normalization, `typeset -f` for hook detection, `emulate -L zsh` for safety in step files). Bash compatibility was traded for cleaner code.

### `.smokerc` as bash-source, not JSON/TOML

The runner is zsh; sourcing `.smokerc` is zero-overhead and supports comments, defaults via `${VAR:-default}`, and inline hook function definitions. JSON/TOML would require parsing, can't carry hook functions, and reads worse for shell folks.

### One opinionated example step file

`steps/01-example.zsh` is the only template. It demonstrates the four most-violated rules inline:
- Absolute paths.
- `RUN_OUT` not `out`.
- `verify` for gates, `log` for info.
- Idempotent Setup → Steps → Teardown structure.

Authors copy it as the structural starting point. Comment density is high on purpose.

### Walk-up boundary at `.git` / `$HOME`

If the runner walked all the way to `/`, it would happily pick up an unrelated parent project's `.smokerc`. Halting at `.git` means each repo's framework is self-contained. `$HOME` is the secondary boundary for non-repo workspaces.

---

## What this skill is NOT

- **Not a unit-testing replacement.** Smoke runs the *binary*, end-to-end, against real infrastructure. Your project's `bun test` / `pytest` / `cargo test` continues unchanged. The two are complementary:

  | | Smoke | Unit |
  |---|---|---|
  | Surface | compiled binary | individual functions |
  | Environment | real (Docker, ports, FS, network) | DI fakes / `tmpdir` / mocks |
  | Runtime | seconds-to-minutes per section | milliseconds per case |
  | Failure | binary regression vs real env | logic regression at function boundary |

- **Not a paste-and-run framework.** Markdown smoke tests with fenced shell blocks are unsupported. The framework's first iteration was paste-and-run; the second was executable. The executable form survived; the paste form did not.

- **Not Windows-compatible.** zsh, tmux, perl, lsof, jq required. macOS and Linux only.

- **Not a log-distillation tool.** A predecessor framework shipped a `smoke-distill.sh` to strip noise from paste-and-run transcripts. The executable runner emits structured `$RUN_LOG` directly; no distill stage needed.

- **Not a CI integrator.** No GitHub Actions snippet, no Jenkinsfile generator. The runner is a zsh script that exits 0 on pass, 1 on fail — wire it into whatever CI you use.

- **Not auto-upgrading.** `/smoke-init --force` gives you a one-shot overwrite-with-backup. No per-file diff/merge tooling. (Deferred until a second consumer appears with a real upgrade pain point.)

- **Not opinionated about your project's smoke-test conventions** beyond the framework itself. Where `.smokerc` goes, what `BUILD_CMD` does, what shape your hooks take — your call.

---

## Install

When the skill is published to a Claude Code plugin marketplace:

```
/plugin install smoke-test-skill
```

Or clone + symlink for local testing:

```bash
git clone https://github.com/<owner>/smoke-test-skill ~/.claude/plugins/cache/smoke-test-skill
```

---

## Use

In your project, in Claude Code:

```
/smoke-init
```

Answer the prompts. The first runner is scaffolded immediately; run it:

```bash
docs/superpowers/smoke-tests/<topic>/run.zsh
```

Add more runners (run from inside the install dir so the walk-up resolves):

```
/smoke-add <new-topic>
```

Author a new section: see the scaffolded `<install-path>/AUTHORING_GUIDE.md`.

---

## Requirements

| Tool       | Why |
|------------|-----|
| zsh        | Runtime shell for runners and lib helpers. |
| bash       | shellcheck CI gate uses bash dialect. |
| tmux       | Real pty for TTY-required SUT commands. |
| perl       | `alarm()` for budget enforcement. |
| lsof       | `wait_for_port` LISTEN check. |
| jq         | Structured assertions in step files. |
| shellcheck | Developer-side CI gate (not runtime). |

Plus whatever your `BUILD_CMD` needs (Bun, Rust, Go, Node, Python, etc.).

---

## Develop

```bash
git clone <this-repo>
cd smoke-test-skill
bun install
bun test          # 23 tests
```

Tests cover scaffold scripts (init/add/force/walk-up/token-substitution), runner behavior (binary check, empty config, preflight, budget timeout), hooks (pre_run/post_run), and `shellcheck` cleanliness across all shipped zsh files. A fake SUT (`tests/fixtures/fake-sut.zsh`) lets runner tests execute end-to-end without a real binary or Docker dependency.

---

## License

MIT.
