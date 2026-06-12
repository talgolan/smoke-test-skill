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

## Scaffolder logic (smoke-init / smoke-add / smoke-sync)

### #11 — The shared-lib sync was coupled to `smoke-add`'s --topic, so pulling a lib fix forced scaffolding an unwanted runner (2026-06-12)

**The gap.** The version-gated `sync_lib` (the #21/v0.5.0 mechanism) was wired ONLY into `smoke-add`, which hard-requires `--topic` (`exit 2` without it). So a consumer who just wanted the latest shared `lib/` + `AUTHORING_GUIDE.md` (e.g. itb after the skill shipped v0.6.0's `cap` helper) had to create a runner they didn't want, or run the heavyweight `/smoke-init --force` (re-scaffolds everything). Two unrelated concerns — "sync the shared lib" and "create a runner" — were fused.

**Why it can't auto-update instead.** The installed lib is committed into the consumer repo; the only thing that runs there (`run.zsh`) resolves `$SMOKE_LIB` to that committed copy and has NO path to the skill payload (which lives in `~/.claude/plugins/cache/.../<ver>/payload/`, reachable only from the Claude Code command context). A skill has no runtime presence in the consumer repo — no daemon, no hook — so "refresh on plugin reload" is structurally impossible. The sync MUST be initiated by a slash command. Freezing-by-default is also intentional (reproducible CI, no mid-PR behavior drift).

**Fix.** New `/smoke-sync` command (`scripts/smoke-sync.zsh` + `commands/smoke-sync.toml`): lib-only, version-gated, no `--topic`. To avoid drift between it and `smoke-add`, extracted the two shared blocks into `lib-sync.zsh` — `resolve_install_dir <path>` (the explicit-path / walk-up / .git-fallback discovery) and `sync_lib_if_behind <payload> <install> <plugin_json>` (the version compare + copy + stamp, rc 0/1/2 = synced/current/newer). `smoke-add` now calls both (behavior unchanged — its 15 tests stayed green); `smoke-sync` is a thin wrapper. This honors lib-sync.zsh's own charter ("the install block lives in exactly one place and the two paths cannot drift") — generalize the mechanism, don't add a third copy. +6 sync tests + 1 shellcheck file. v0.7.0.

### #5 — Per-`pdir` isolation does not cover GLOBAL SUT state (docker images, global installs, daemons) — surfaced by an itb consumer (2026-05-30)

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

## Authoring real-system smoke sections

These are skill-authoring lessons surfaced by the itb `engine-preflight`
consumer (itb PRs #57 + #58, 2026-06-11) — sections that drive a real
daemon/system service through the SUT's control path. They're baked into
`payload/AUTHORING_GUIDE.md` §14/§15 + §8 rules 17/18; recorded here so the
provenance survives.

### #10 — Assert the post-condition, not the launcher's exit code or output — a launcher can print a cosmetic error on a HEALTHY service (2026-06-11)

**The trap.** itb engine-preflight §08 asserted "start sequence printed NO error" by grepping the pane log for `XPC connection error|internalError`. Apple `container system start` exits 1 with exactly that cosmetic XPC error on EVERY invocation — even a warm, already-running daemon (`container ls` works immediately after). So the assertion false-failed a fully healthy daemon.

**Why.** A `start`/`up`/`enable` command's exit code and stdout are a PROXY; the service's readiness is the invariant. A verification probe inside the launcher can race the service settling, or the launcher can be idempotently noisy. itb itself is unaffected — `preflight.ts:startAndWait` ignores start's rc and polls `container system status` until green.

**Fix.** Removed the no-error assertion (AUTHORING_GUIDE §8 rule 18 + §9 grep check 9). Assert the END STATE instead: poll the readiness check, or wait for the SUT's own ready message (itb prints "No itb containers found" only AFTER its status poll goes green, so that message IS proof). This is the over-correction twin of §8 rule 14 (don't poll success-only) — both reduce to: key on the genuine post-condition. (Originating: itb LEARNINGS #141.)

### #9 — A daemon-control command can HANG; wrap it in a per-command hard cap (`cap`) (2026-06-11)

**The trap.** Apple `container system stop` blocked ~2 min on a sick apiserver during §08 authoring. The per-section `alarm` budget is too coarse — it fails the WHOLE section after minutes, and the runner just looks dead in the meantime.

**Fix.** New `cap <secs> <cmd>...` in `payload/lib/control.zsh` — the per-COMMAND analogue of the per-section budget. Runs the command, kills it at N seconds (TERM then KILL), returns the command's real rc or 124 on timeout (coreutils `timeout` convention). stdout flows through so `OUT=$(cap 10 svc status)` captures. AUTHORING_GUIDE §8 rule 17 + §14 rule 1. `cap` lives in `control.zsh` (already in the lib-sync cp list) precisely to avoid the #1 trap — a new lib FILE would need a `lib-sync.zsh`/`smoke-init.zsh` cp-list edit.

### #8 — The live tmux pane is destroyed when the SUT exits; poll the persistent pane LOG for a just-before-exit signal (2026-06-11)

**The trap.** `term_a_pane_grep` polls the LIVE pane and needs `tmux has-session` true while polling. itb §05 keyed its completion check on it for `itb list`, which prints its result and exits immediately after a successful preflight. The session closed before the poll fired → no match → "list did not complete", while the pane LOG plainly held the success message.

**Fix.** For a signal the SUT prints just before exiting, poll the persistent `logs/<NN>-<slug>-pane.log` (written by `term_a_start`'s `tmux pipe-pane`, survives the session), not the live pane. Dual-signal, keyed on the EXACT message — a loose alternation can match a path/name echo and pass spuriously. AUTHORING_GUIDE §10. Doc-only fix (no new helper): the idiom appears once in §14 and is cheap to inline. (Originating: itb LEARNINGS #140.)

### #7 — Auto-driven manual ≠ operator-paused manual — name the two shapes (2026-06-11)

**The gap.** The skill documented `pause` (operator does a thing) and `MANUAL_SECTIONS` (excluded from no-arg run) but never named the two DISTINCT reasons a section is manual. **(a) Operator-paused** — a human MUST act/eyeball (a GUI step, a `open -a Docker` with no scriptable stop); use `pause`, backend-agnostic. **(b) Auto-driven manual** — fully scripted, no keystrokes, but excluded because it MUTATES shared machine state (stops a daemon, removes an image); self-skips on wrong OS/backend, restores state at the end.

**Rule.** Choose (b) whenever the action is CLI-scriptable — repeatable, fast, no operator attention. Keep a human in the loop only for a step no CLI can perform. AUTHORING_GUIDE §15 (itb §07 = (a), §08 = (b)).

### #6 — An unquoted heredoc that GENERATES a script runs its backticks/`$()` against the operator's real environment AT AUTHOR TIME (2026-06-11)

**The trap.** A hermetic PATH-shim section generated a fake engine CLI with `cat > "$shim" <<SHIM ... SHIM` (UNQUOTED delimiter). A harmless-looking comment in the body — `` # Docker readiness probe: `docker info` `` — was command-substituted at GENERATION time: it ran the operator's real `docker info` and spliced the multi-line output into the shim, producing `syntax error near unexpected token '('` on text that exists nowhere in the source.

**Fix.** Use a QUOTED delimiter (`<<'SHIM'`) so nothing in the body expands — backticks, `$(...)`, `$VAR` all stay literal. Interpolate the few values you need via an explicit header line written before the quoted body (`print -r -- "STATE_FILE='$path'"`). **zsh twin (itb #138):** zsh's `printf` has no `%q` — `printf '...%q...'` errors `illegal format character q` and writes a malformed file; use `print -r --` and single-quote the value yourself, or `${(q)var}`. Both bite anyone authoring a hermetic PATH-shim section. (Originating: itb LEARNINGS #137 + #138.)

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

*Last entry: 2026-06-12 (#11 — shared-lib sync was coupled to smoke-add's
--topic; added /smoke-sync + extracted resolve_install_dir/sync_lib_if_behind
into lib-sync.zsh). Add new entries at the top of each section as they
surface. The `/session-continuity:learning` command bumps this line
automatically. Rule of thumb: if a bug takes more than 15 minutes to
diagnose, it goes here.*

*Numbering note: new entries take the next available number (N+1) and
are placed at the top of their section. Old entries keep their numbers
so historical references ("see #7 above") stay valid even when the
visual order no longer matches numeric order.*
