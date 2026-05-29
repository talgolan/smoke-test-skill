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

## Scaffolder logic (smoke-init / smoke-add)

<!-- TBD — walk-up boundary, token substitution, --force backup behavior. -->

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

*Last entry: 2026-05-29 (#0 — file initialized, no entries yet). Add
new entries at the top of each section as they surface. The
`/session-continuity:learning` command bumps this line automatically.
Rule of thumb: if a bug takes more than 15 minutes to diagnose, it
goes here.*

*Numbering note: new entries take the next available number (N+1) and
are placed at the top of their section. Old entries keep their numbers
so historical references ("see #7 above") stay valid even when the
visual order no longer matches numeric order.*
