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

<!-- TBD — walk-up boundary, token substitution, --force backup behavior. -->

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

*Last entry: 2026-05-29 (#2 — plugin.json `author` must be object). Add
new entries at the top of each section as they surface. The
`/session-continuity:learning` command bumps this line automatically.
Rule of thumb: if a bug takes more than 15 minutes to diagnose, it
goes here.*

*Numbering note: new entries take the next available number (N+1) and
are placed at the top of their section. Old entries keep their numbers
so historical references ("see #7 above") stay valid even when the
visual order no longer matches numeric order.*
