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
bun test   # 27 pass / 0 fail
```

8 of the 27 tests run `shellcheck` against shipped zsh files. They
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

- v0.1.0 published; README comprehensive; manual sandbox
  integration test passed.
- Active branch is `main`. PR #1 (duration-history spec) merged.
  Two follow-up fixes landed for plugin marketplace install:
  `source` schema and `author` schema. See LEARNINGS #1, #2.
- Walk-up boundary UX gap (was outstanding #1) **resolved**: smoke-add
  now accepts `--install-path <path>` AND falls back to
  `<git-root>/docs/superpowers/smoke-tests/.smokerc` when walk-up halts
  at `.git`. 4 new tests cover the fallback + explicit-path cases.

**Current `git log --oneline -5` (HEAD):**

```
{{HEAD_AFTER_COMMIT}}
```

Regenerate this block whenever you commit — see "Primer maintenance"
below.

## Outstanding items (explicitly deferred — not bugs, decisions)

_None at HEAD._ Previous outstanding #1 (walk-up boundary UX gap)
resolved — see "Current state".

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

When a bug takes more than 15 minutes to diagnose, update
`.session-continuity/LEARNINGS.md` too (see that file's footer for
numbering rules).
