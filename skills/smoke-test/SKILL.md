---
name: smoke-test
description: Scaffold an executable smoke-test framework into a project. Use when the user says "set up smoke testing", "add smoke testing", "add smoke test for X", or asks to install/run smoke tests in a fresh project. Two commands: /smoke-init bootstraps the framework + first runner; /smoke-add adds additional runners.
---

# smoke-test skill

Provides two slash commands that scaffold an executable end-to-end smoke-test harness into a target project. The harness is generic — any binary SUT, any project layout — driven by a per-project `.smokerc`.

## When to invoke

| User says | Action |
|---|---|
| "set up smoke testing", "add smoke testing", "I want smoke tests" | `/smoke-init` |
| "add a smoke test for X", "new smoke runner", "scaffold a runner for X" | `/smoke-add X` |
| "smoke run failed, what's wrong" | Read `<install-path>/<topic>/logs/run-<latest>.log` directly. Don't reinvoke. |
| "how do I write a smoke step" | Open `<install-path>/AUTHORING_GUIDE.md`. |

## Decision tree

```
User wants smoke testing in this project.
├── Is `<install-path>/.smokerc` already present?
│   ├── Yes → `/smoke-add <topic>` for the new runner.
│   └── No  → `/smoke-init` (interactive: prompts for topic, SUT_BIN, SUT_REPO, BUILD_CMD).
```

If unsure which install path the project uses, walk up from `$PWD` looking for `.smokerc` (boundary: `.git` dir or `$HOME`).

## Slash commands

### `/smoke-init [args]`

Args (all optional except interactive prompts will fill the gaps):
- `--install-path <path>` — default `docs/superpowers/smoke-tests`
- `--topic <name>` — first runner name
- `--force` — overwrite existing install (sibling backup at `<path>.backup-<ts>/`)

### `/smoke-add <topic>`

Walks up from `$PWD` to find `.smokerc`, then scaffolds `<install-path>/<topic>/` with `run.zsh`, `steps/01-example.zsh`, `README.md`, and a `lib/<topic>-helpers.zsh` stub (auto-sourced by `run.zsh` in both scopes). Refuses if `<topic>` dir exists.

## Hard rules (every session)

1. **Never author paste-and-run markdown smoke tests.** This skill ships only the executable harness; markdown tests are not supported.
2. **Never put `cd` outside Teardown** in step files. Sub-shell `cd` doesn't persist; absolute paths only.
3. **Read `<install-path>/AUTHORING_GUIDE.md` before authoring step files.** Every rule there is real.
4. **Run the AUTHORING_GUIDE grep gate** before committing step files.
5. **Smoke tests are NOT a substitute for unit tests.** The project's `bun test` / `pytest` / `cargo test` continues unchanged. Smoke runs the *binary*, not functions.
6. **Monitor long-running smoke runs at the printed interval.** `run.zsh` emits per-section poll intervals in its pre-run banner (computed from history p95). Tail `<topic>/logs/run-<latest>.log` at that cadence. Two consecutive empty polls AND no advancement past the section header = hung; kill (`pkill -f run.zsh`, `tmux kill-session -t <slug>` for any active term-a sessions) and investigate. New sections without history default to 15 s. Share the banner's expected-duration table with the user before running so both sides know what "normal" looks like.

## File map after `/smoke-init`

```
<install-path>/
├── .smokerc                 # SUT_BIN, SUT_REPO, BUILD_CMD, hooks
├── lib/                     # shared zsh helpers (don't edit per-runner)
│   ├── env.zsh
│   ├── log.zsh
│   ├── term-a.zsh
│   ├── pause.zsh
│   ├── history.zsh          # duration history + adaptive recommendations
│   ├── README.md
│   └── .skill-version
├── AUTHORING_GUIDE.md       # how to author step files
└── <first-topic>/
    ├── run.zsh              # controller
    ├── .history.jsonl       # per-section duration history (append-only, capped)
    ├── lib/                 # topic-local helpers, auto-sourced (both scopes)
    │   └── <topic>-helpers.zsh
    ├── steps/01-example.zsh
    ├── logs/
    └── README.md
```

## What this skill does NOT do

- Doesn't ship `smoke-distill.sh` (the executable runner emits structured logs already).
- Doesn't replace, suppress, or interfere with your project's unit-test workflow.
- Doesn't migrate existing markdown smoke tests automatically — author new executable runners alongside.
- Doesn't support Windows (zsh + tmux + perl + lsof required).

## Commands

`/smoke-init` invokes the script at `${CLAUDE_PLUGIN_ROOT}/scripts/smoke-init.zsh`. (Phase 6 verifies this is the canonical plugin-root env-var name.)

`/smoke-add` invokes `${CLAUDE_PLUGIN_ROOT}/scripts/smoke-add.zsh`.
