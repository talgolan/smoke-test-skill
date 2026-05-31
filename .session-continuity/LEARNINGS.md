# Learnings — smoke-test-skill

This is a graveyard of subtle, painful bugs we've hit while building
smoke-test-skill. Each entry is a recipe for a future engineer (or
future Claude) to avoid re-discovering what was expensive to discover
the first time. Entries are grouped by layer, most-painful-first
within each group.

Many of the original lessons are baked into the shipped
`payload/AUTHORING_GUIDE.md` because they apply to authors of step
files in *target* projects. This file captures the meta-level lessons
about building the *skill itself* — scaffolders, tests, payload
generation.

---

## Shell scripts

<!-- TBD — populate as bugs surface during skill development. -->

---

## Bun test harness

<!-- TBD -->

---

## Primer maintenance

### #3 — Primer log block can't include the SHA of the commit shipping it (2026-05-29)

**Symptom.** Refreshed `git log --oneline -5` block in primer → staged
+ committed → primer commit's own SHA is now HEAD, but the log block
inside still shows the *previous* HEAD. Trying to write the new SHA
before committing means putting a placeholder (`{{HEAD_AFTER_COMMIT}}`)
that, in this session, accidentally shipped to disk.

**Why.** The log block is a snapshot of `git log` at the moment of
authoring. The commit that lands the snapshot is, by definition, not
yet in `git log` at authoring time. There's a chicken-and-egg loop.

**Fix.** Don't try to pre-compute the new SHA. Two options:

1. **Snapshot pre-commit, accept one-commit lag** (default). Stage the
   primer with the previous HEAD's log block. The primer is then
   "current as of HEAD~1" — close enough; refresh on the next
   substantive commit catches up.
2. **Catch-up commit immediately after** (rare). Commit the real
   change, then a `docs(primer): refresh log block` follow-up. Worth
   it only if the gap matters; otherwise option 1 is cleaner.

**Hard rule:** never stage a primer with `{{...}}` placeholders. Run
`grep -n '{{' .session-continuity/SESSION_PRIMER.md` before
`git add` — must return nothing.

---

## Scaffolder logic (smoke-init / smoke-add)

### #5 — Per-`pdir` isolation does not cover GLOBAL SUT state (docker images, global installs, daemons) — surfaced by an itb consumer (2026-05-30)

**The trap.** The framework's isolation model is per-section `pdir` under `$SMOKE_ROOT`: setup creates it, teardown `rm -rf`s it. That covers filesystem state in the workspace. It does NOT cover state the SUT writes OUTSIDE the workspace — docker images/containers (global to the daemon), `npm -g`/`brew` global installs, system services, shared caches. A consumer's `sf-harness` runner used an isolated `ITB_HOME`, but `itb run` execs into a docker image (`itb-final:latest`) that is GLOBAL to the daemon. A stale image from an unrelated earlier session (different harness selection, no node) was silently reused; poststart died with `npm: command not found`. The test pointed at the install logic for ~20 min until `docker inspect <name> --format '{{.Config.Image}}'` revealed it ran the wrong image. Clearing the isolated `$HOME` did nothing.

**Fix.** Added AUTHORING_GUIDE hard rule #13: enumerate the SUT's global side-effects and reset the relevant ones in Setup (e.g. `docker rmi -f <sut-image>:latest` before a build-and-run section). The diagnostic reflex — "X present in what I built but absent at runtime → check WHICH artifact the runtime actually used" — is in the rule.

**Why it matters for the skill.** Any SUT that builds images, installs globally, or manages a daemon has this hazard. The guide now names it instead of leaving each author to rediscover it.

### #4 — A topic helper sourced in `run.zsh` top-level is NOT visible inside the alarm-wrapped step sub-shell unless ALSO sourced there (2026-05-30)

**The trap.** `run.zsh` runs each step inside a `perl -e 'alarm(N); exec' -- zsh -c "<string>"` sub-shell that re-sources the shared `lib/*.zsh` from scratch — the parent shell's functions do NOT carry in. A consumer followed the old AUTHORING_GUIDE §11 ("source it from `<topic>/run.zsh` after `lib/`"), added the source line ONCE at top level, and their first section died with `command not found: <helper>` only when the step ran. The guidance undersold that there are TWO sourcing sites.

**Fix.** The template `run.zsh` now auto-sources `<topic>/lib/*.zsh` (glob, `null_glob`) in BOTH the top-level and the per-section sub-shell, and `/smoke-add` scaffolds a `<topic>/lib/<topic>-helpers.zsh` stub so authors get the pattern for free — no manual `run.zsh` edit. AUTHORING_GUIDE §11 now states the two-scope rule explicitly. Regression test `tests/add-topic-helpers.test.ts` asserts the glob appears exactly twice and that a helper function resolves inside a real step run.

### #1 — Adding a new `payload/lib/*.zsh` file requires updating `scripts/smoke-init.zsh`'s explicit `cp` list (2026-05-29)

**The trap.** `scripts/smoke-init.zsh` enumerates `payload/lib/`
files by name (`cp "$PAYLOAD/lib/env.zsh" ...`, `cp ".../log.zsh"
...`, etc.) instead of `cp -R "$PAYLOAD/lib/" ...` or a glob. New lib
files added to `payload/lib/` are NOT copied into target installs
unless the cp list is updated alongside. Caught this session when
`history.zsh` (newly added in v0.2.0) failed to land in scaffolded
projects — runner started, sourced the missing path, every
`history_*` call became `command not found`, banner showed empty
`p50=s p95=s` columns.

**Symptom.** Scaffolded runner emits to stderr:

```
.../lib/history.zsh:source:80: no such file or directory: .../lib/history.zsh
.../run.zsh:159: command not found: history_stats
.../run.zsh:178: command not found: history_recommend_poll
```

Run still completes (history layer soft-fails) but banner output is
broken.

**Fix.** Add `cp "$PAYLOAD/lib/<new-file>.zsh" "$abs_install/lib/"`
to `scripts/smoke-init.zsh` whenever a new `payload/lib/*.zsh` ships.
Tests catch it: `tests/runner-smoke.test.ts` runs the scaffolder and
the banner assertion fires the moment the file is missing.

**Diagnostic signal.** A `command not found` for a function that's
defined in `payload/lib/` and a missing `lib/<x>.zsh` in the test's
target tmpdir together = `smoke-init.zsh` cp list is incomplete.
Also surfaces in `tests/shellcheck.test.ts` indirectly: shellcheck
runs against `payload/lib/<x>.zsh` (passes) but the runtime
integration test still fails because the file never reaches the
target.

**Prevention candidate** (deferred): switch to `cp -R
"$PAYLOAD/lib/" "$abs_install/lib/"` so additions auto-propagate.
Risk: would also propagate stray scratch files inside `payload/lib/`,
so guard with a known-files allowlist or a `.scaffold-include` glob.
Not blocking; one-line cp adds are cheap.

---

## Plugin marketplace publishing

### #2 — `plugin.json` `author` must be object, not string (2026-05-29)

**Symptom.** `/plugin install` after schema + SSH fixes:

```
Plugin ... has an invalid manifest file at .../.claude-plugin/plugin.json.
Validation errors: author: Invalid input: expected object, received string
```

**Cause.** `plugin.json` had `"author": "Tal Golan"`. Schema requires
an object with at least `name`.

**Fix.**

```json
"author": {
  "name": "Tal Golan"
}
```

`email` optional. Same shape as `marketplace.json` `owner`.

**Stacking trap.** Three independent failures masked each other:
1. `"source": "."` → "version not supported"
2. SSH host key → "Host key verification failed"
3. `"author": "string"` → "invalid manifest"

Only surfaced sequentially. Validate manifest schema locally before
publishing — no upstream linter today.

---

### #1 — `"source": "."` rejected as unsupported source type (2026-05-29)

**Symptom.** `/plugin install smoke-test-skill@talgolan` failed in
Claude Code v2.1.157 with:

```
Failed to install: This plugin uses a source type your Claude Code
version does not support. Update Claude Code and try again.
```

**Misleading message.** Error blames Claude Code version. Real cause
is the `marketplace.json` schema.

**Cause.** `marketplace.json` declared `"source": "."` for a plugin
living at the marketplace repo root. Per docs, relative-path sources
**must start with `./`**. Bare `.` is not in the supported set
(`./...` | `github` | `url` | `git-subdir` | `npm`), so the installer
classifies it as an unknown/future source type and emits the
version-mismatch error instead of a schema error.

**Fix.** When the plugin lives in the same repo as `marketplace.json`,
prefer an explicit `github` object — works regardless of how the
marketplace was added (clone, URL, ref pin) and avoids the
"plugin-at-repo-root" relative-path edge case entirely:

```json
"source": {
  "source": "github",
  "repo": "owner/repo"
}
```

If you need a relative path (multi-plugin marketplace, plugin in a
subdir), use `"./plugins/foo"` — leading `./` is required.

**How to spot it next time.** "Source type your Claude Code version
does not support" with a recent CC version → suspect malformed
`source` field before suspecting CC. Compare against the table at
https://code.claude.com/docs/en/plugin-marketplaces#plugin-sources.

---

## Security incidents

<!-- None recorded. -->

---

## Anti-patterns we were tempted by (and rejected)

<!-- TBD — see README "Design decisions and tradeoffs" for the
public-facing version of this. -->

---

## Checklist for a fresh dev-env setup

1. `git clone https://github.com/talgolan/smoke-test-skill && cd smoke-test-skill`
2. `bun install`
3. Install `shellcheck` (Ubuntu: `sudo apt-get install shellcheck`;
   macOS: `brew install shellcheck`). Without it, 8 shellcheck-tagged
   tests fail environmentally.
4. `bun test` — expect 23/23 pass.

---

*Last entry: 2026-05-30 (#4 topic-helper two-scope sourcing, #5 global-SUT-state hermeticity — both surfaced by the itb sf-harness consumer). Add
new entries at the top of each section as they surface. The
`/session-continuity:learning` command bumps this line automatically.
Rule of thumb: if a bug takes more than 15 minutes to diagnose, it
goes here.*

*Numbering note: new entries take the next available number (N+1) and
are placed at the top of their section. Old entries keep their numbers
so historical references ("see #7 above") stay valid even when the
visual order no longer matches numeric order.*
