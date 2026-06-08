# smoke-add lib sync — design

**Date:** 2026-06-04
**Status:** approved, pre-implementation
**Origin:** itb outstanding item #21. Discovered 2026-06-03 while scaffolding
the itb dev-build-loop runner.

## Problem

`/smoke-add` (`scripts/smoke-add.zsh`) copies a current-version `run.zsh`
from `payload/template/` but never touches the installed shared `lib/`.
Only `/smoke-init` (`scripts/smoke-init.zsh`) installs `lib/` (lines 70-86:
eight `cp`s + `AUTHORING_GUIDE.md` + a `.skill-version` stamp).

Consequence: the installed `lib/` stays frozen at whatever version
`smoke-init` last wrote, while every `smoke-add` pulls a newer `run.zsh`.
When that newer `run.zsh` sources a helper the frozen lib lacks (e.g.
`control.zsh`, added in v0.4.0), the runner dies with `no such file` at
`--list`.

Observed in itb: installed lib frozen at 0.2.0, `smoke-add` pulled a 0.4.0
`run.zsh` sourcing `control.zsh`. Worked around by manually syncing the
whole lib. The fix belongs upstream here.

User directive: "fix the /smoke-test skill — it must upgrade all
dependencies."

## Approach: version-gated sync

Before scaffolding the topic, `smoke-add` compares the installed
`lib/.skill-version` to the skill's `plugin.json` version. If installed <
skill, re-copy the full shared lib + `AUTHORING_GUIDE.md` and re-stamp
`.skill-version`. Otherwise no-op.

Version-gated (not unconditional-always) chosen to avoid pointless I/O and
a spurious "synced" log line on every routine `smoke-add` when already
current. End state is identical to always-sync; only the no-op path differs.

## Components

### 1. `scripts/lib-sync.zsh` (new, sourced helper)

Single source of truth for "what the shared lib is and how to install it."
Three functions:

- **`skill_version <plugin_json>`** → echoes the skill version. Reads
  `.version` via `jq` when `jq` present and the file exists; otherwise
  echoes `0.0.1`. Mirrors the existing init fallback exactly.

- **`sync_lib <payload> <abs_install> <version>`** → the install block
  currently inlined in `smoke-init.zsh` lines 70-86: `mkdir -p
  <abs_install>/lib`, the eight `cp`s (env/log/control/term-a/pause/history
  zsh + lib README), `cp AUTHORING_GUIDE.md`, and write `<version>` to
  `lib/.skill-version`.

- **`version_lt <a> <b>`** → returns 0 (true) iff `a < b` by semver field
  compare. Pure zsh, no external deps:
  - split each on `.`; pad the shorter with `0` fields
  - compare field-by-field as base-10 ints (`10#$f` to avoid octal
    interpretation of leading-zero fields)
  - non-numeric field → treated as `0` (defensive; skill versions are
    always numeric `X.Y.Z`, no pre-release tags)
  - first differing field decides; all-equal → false

  Examples: `0.2.0 < 0.4.0` true; `0.4.0 < 0.4.0` false;
  `0.4.0 < 0.2.0` false; `0.0.0 < 0.4.0` true.

`smoke-init.zsh` refactored to source `lib-sync.zsh` and call
`sync_lib "$PAYLOAD" "$abs_install" "$(skill_version "$plugin_json")"` in
place of its inlined block. Removes duplication so a lib file added in one
path cannot drift from the other.

### 2. `smoke-add.zsh` change

After `abs_install` is resolved (current line 81) and before the topic
scaffold (current line 83), source `lib-sync.zsh` and:

```zsh
plugin_json="$SCRIPT_DIR/../.claude-plugin/plugin.json"
current=$(skill_version "$plugin_json")
installed=$(cat "$abs_install/lib/.skill-version" 2>/dev/null || echo 0.0.0)
if version_lt "$installed" "$current"; then
  sync_lib "$PAYLOAD" "$abs_install" "$current"
  print -- "  synced shared lib $installed → $current"
elif version_lt "$current" "$installed"; then
  print -u2 "  note: installed lib ($installed) newer than skill ($current); leaving as-is"
fi
```

## Edge cases (decided)

| Case | Behavior |
|---|---|
| Missing `.skill-version` | treated as `0.0.0` → sync (covers pre-versioning installs) |
| Installed == skill | no-op, silent |
| Installed > skill (downgrade / dev binary newer than target) | no-op + one-line note to stderr; never clobber backward |
| `jq` absent | `skill_version` returns `0.0.1`; syncs only if installed < `0.0.1` (i.e. missing/`0.0.0`). Same degradation init already accepts. |
| Local edits to installed `lib/` | clobbered on upgrade. Acceptable: lib is skill-owned, upgrades are additive-safe (verified against itb's 5 runners). Not backed up — `smoke-init --force` is the back-up path; `smoke-add` is routine. |

## Testing

New `tests/add-lib-sync.test.ts`:
- stale `.skill-version` (`0.2.0`) in a seeded install → after `smoke-add`,
  lib re-copied, stamp bumped to current (`0.4.0`), `control.zsh` present.
- current version stamp → lib untouched (content unchanged), no sync line
  in stdout.
- missing `.skill-version` → synced.
- installed newer than skill (`9.9.9`) → not downgraded; stamp unchanged;
  stderr note emitted.

Existing `init-fresh` / `init-force` / `init-existing-no-force` tests must
stay green after the refactor — proves extraction didn't change init
behavior.

`shellcheck.test.ts` FILES list extended with `scripts/lib-sync.zsh`; must
stay clean.

`bun test` 50 → ~54. `plugin.json` version bump on release of this change
(0.4.0 → 0.5.0) so downstream installs detect the skew and pull lib-sync
itself.

## Non-goals

- No backup of clobbered local lib edits (lib is skill-owned).
- No partial / per-file sync — full lib copy is cheap and keeps the set
  consistent.
- No change to `run.zsh` runtime behavior or to the payload lib contents.
