# Manual integration test — 2026-05-29

Sandbox: `/tmp/smoke-skill-sandbox`. SUT: a 2-line zsh script `sandbox-bin` printing `sandbox-bin 1.0`.

| Step | Result |
|---|---|
| `/smoke-init --install-path docs/superpowers/smoke-tests --topic firstrunner --non-interactive --sut-bin <path> --sut-repo <path> --build-cmd ':' --preflight 'tmux jq'` | PASS — scaffolded `lib/`, `AUTHORING_GUIDE.md`, `.smokerc`, `firstrunner/` |
| `firstrunner/run.zsh` | PASS in 0s (3 verifies: pdir, binary executable, version prints) |
| `cd <install-path> && /smoke-add --topic secondrunner` | PASS — scaffolded `secondrunner/` |
| `secondrunner/run.zsh` | PASS in 0s |

## Issues encountered

1. **Walk-up boundary UX gap.** Running `smoke-add --topic secondrunner` from the sandbox root (`/tmp/smoke-skill-sandbox`) failed: walk-up halted at `.git` before finding `.smokerc` (which lives at `docs/superpowers/smoke-tests/.smokerc`). Workaround: `cd` into the install dir first. Permanent fix (v0.2): smoke-add could also try `<repo-root>/docs/superpowers/smoke-tests/.smokerc` as a fallback default before failing, OR accept an explicit `--install-path` argument that bypasses walk-up.

   Not blocking v0.1.0 — slash-command toml prompts the model to call from project root, which works once we ship better UX. Tracked as v0.2 follow-up.
