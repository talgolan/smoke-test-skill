# smoke-test-skill

Standalone Claude Code plugin: scaffolds an executable smoke-test framework into any project.

## What it gives you

Two slash commands:

- `/smoke-init` — scaffolds the framework into a target project (default install path: `docs/superpowers/smoke-tests/`). Interactive prompts for `SUT_BIN`, `SUT_REPO`, `BUILD_CMD`. Also creates the first runner.
- `/smoke-add <topic>` — scaffolds an additional runner from the template.

A scaffolded project gets:

```
<install-path>/
├── .smokerc                 # config: SUT_BIN, SUT_REPO, BUILD_CMD, hooks
├── lib/                     # shared zsh helpers (env, log, term-a, pause)
├── AUTHORING_GUIDE.md       # how to author step files (every rule has a real failure attached)
└── <topic>/
    ├── run.zsh              # controller (sections, budgets, summary)
    ├── steps/01-example.zsh # opinionated template demonstrating the rules
    └── README.md
```

`run.zsh` discovers its install path by walking up from itself (boundary: `.git` dir or `$HOME`), so `.smokerc` is project-local and never fights an unrelated parent.

## Install

Add to your Claude Code plugin marketplace, then:

```
/plugin install smoke-test-skill
```

Or clone + symlink:

```bash
git clone https://github.com/<owner>/smoke-test-skill ~/.claude/plugins/cache/smoke-test-skill
```

## Use

In your project, in Claude Code:

```
/smoke-init
```

Answer the prompts. The first runner runs immediately:

```bash
docs/superpowers/smoke-tests/<topic>/run.zsh
```

Add more (run from inside the install dir):

```
/smoke-add <new-topic>
```

## Smoke vs unit testing

This skill is for **end-to-end binary smoke testing**, not unit testing. Your project's `bun test` / `pytest` / `cargo test` is unaffected. The two are complementary:

| | Smoke | Unit |
|---|---|---|
| Surface | compiled binary | individual functions |
| Environment | real (Docker, ports, FS, network) | DI fakes / `tmpdir` / mocks |
| Runtime | seconds-to-minutes per section | milliseconds per case |

## Requirements

- macOS or Linux.
- zsh, bash, tmux, perl, lsof, jq.
- `shellcheck` for the CI gate (developer-side only).
- Whatever your `BUILD_CMD` needs (Bun, Rust, Go, etc.).

Windows is not supported.

## Develop

```bash
git clone <this-repo>
cd smoke-test-skill
bun install
bun test          # 23 tests
```

## License

MIT.
