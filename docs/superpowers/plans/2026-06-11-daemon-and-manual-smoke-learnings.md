# Plan — Backport itb daemon/manual-smoke learnings into smoke-test-skill

> **For the next session.** Execute this plan in
> `/Users/tal.golan/active_development/TG/smoke-test-skill`. It is a
> documentation + small-helper update to the smoke-test skill, distilling
> hard-won learnings from the itb `engine-preflight` smoke work (2026-06-11,
> itb PRs #57 + #58, itb LEARNINGS #137–#141).
>
> **Author context for the executor:** read this whole file first, then read
> `.session-continuity/SESSION_PRIMER.md` + `.session-continuity/LEARNINGS.md`
> in THIS repo before touching anything. Match existing prose voice in
> `payload/AUTHORING_GUIDE.md` (numbered sections, "Originating:" provenance
> notes on hard rules, terse imperative). This is the smoke-test skill's OWN
> repo — its `bun test` suite + `shellcheck.test.ts` gate every change.

**Goal:** Teach the skill four things it does not currently cover, all surfaced
this session: (1) how to author a smoke section that drives a **real daemon/
system service** (stop→ladder→start→poll), (2) the distinction between
**operator-paused** and **auto-driven** manual sections, (3) **assert the
post-condition, not the launcher's exit code/output** (a launcher can exit
non-zero or print a scary-but-cosmetic error while the service is fine), and
(4) two mechanical seams the live itb work exposed — the **hard-timeout cap**
for hang-prone system commands, and the **live-pane-vs-pane-log race** for
fast-exiting SUTs.

**Architecture:** Almost entirely additive docs in `payload/AUTHORING_GUIDE.md`
+ five new LEARNINGS entries here. ONE new shared helper (`cap` hard-timeout
wrapper) in `payload/lib/control.zsh`, which forces a `sync_lib` cp-list touch
+ a `lib/README.md` row + a unit test. ONE new helper
(`term_a_pane_log_grep` or doc-only guidance) for the pane-log race — decide
during execution (see Task 4 decision gate).

**Tech stack:** zsh payload, Bun/TypeScript test harness, the skill's
`lib-sync.zsh` install seam.

---

## Why these and not the others (scope gate — read before adding anything)

The skill ALREADY covers, and these must NOT be re-documented:

- Operator `pause` / `confirm` prompts → `payload/lib/pause.zsh`, AUTHORING_GUIDE
  primitives table + §12 reference.
- `MANUAL_SECTIONS` mechanism (exclude from no-arg run, `--all` to include,
  `[manual]` tag in `--list`) → `payload/template/run.zsh`.
- Driving an interactive **SUT's own prompts** via `term_a_answer` → §12.
- Real authed external **service** (token via env, redact, skip-when-absent,
  read-only round-trip) → §13.
- Dual-signal `poll_until` (success AND failure) → §8 rule 14 + primitive.
- `smoke_keep_on_fail` evidence preservation → §10.
- Global-state reset (daemons/images/global installs in setup) → §8 rule 13.

What this session proved the skill does NOT yet say is below. If during
execution you find any item is in fact already covered, SKIP it and note the
skip in the commit body — do not pad.

---

## File structure

- **Modify:** `payload/AUTHORING_GUIDE.md` — add §14 (daemon/system-service
  sections), §15 (manual section taxonomy: paused vs auto-driven), extend §8
  (new hard rules), extend §9 (grep-gate checks), extend §10 (the pane-log
  race under "After a failure").
- **Modify:** `payload/lib/control.zsh` — add `cap` hard-timeout helper.
- **Modify:** `payload/lib/README.md` — document `cap` (and pane-log helper if
  added).
- **Modify:** `scripts/lib-sync.zsh` — NOT needed for `control.zsh` (already in
  the cp list) — but VERIFY (Task 1 gate). Only edited if a NEW lib FILE is
  added (it should not be).
- **Modify:** `.session-continuity/LEARNINGS.md` — 5 new entries (new section
  "Authoring real-system smoke sections").
- **Modify:** `.session-continuity/SESSION_PRIMER.md` — current-state + test
  count if it changes.
- **Create:** `tests/control-cap.test.ts` — unit test for `cap`.
- **Maybe create:** a pane-log helper test, if Task 4 adds a helper.

---

## Task 1: Verify the install seam before authoring (no code)

**Files:** none — investigation gate.

- [ ] **Step 1:** Confirm `payload/lib/control.zsh` is already in
  `sync_lib`'s cp list (`scripts/lib-sync.zsh`). It is (line ~31 as of v0.5.0).
  So adding a FUNCTION to `control.zsh` needs NO cp-list edit — the file is
  already synced. This is the whole reason `cap` goes in `control.zsh` and not
  a new file: avoids the LEARNINGS #1 trap (new lib FILE ⇒ must edit
  `smoke-init.zsh`/`lib-sync.zsh` cp list, easily forgotten).

- [ ] **Step 2:** Confirm there is NO `cap`/timeout helper already. Run:
  `grep -rnE '\bcap\b|alarm|timeout|perl -e' payload/lib/`. Expected: only the
  per-section budget `perl -e 'alarm(N); exec'` in `payload/template/run.zsh`
  (that wraps a whole SECTION; `cap` wraps a single hang-prone COMMAND inside a
  section — different scope). If a command-level cap already exists, STOP and
  re-scope this task to documenting it instead.

- [ ] **Step 3:** Confirm the pane-grep race is real: read
  `payload/lib/term-a.zsh` `term_a_pane_grep` — it uses `tmux capture-pane -p`
  (LIVE pane). A SUT that exits in <2s (the poll interval) before the grep runs
  loses its pane. Confirm `term_a_start` pipes to a persistent
  `logs/<NN>-<slug>-pane.log` (it does — `tmux pipe-pane`). The persistent log
  survives the session; the live pane does not. This is the seam Task 4
  addresses.

---

## Task 2: AUTHORING_GUIDE §14 — daemon / system-service sections

**Files:** Modify `payload/AUTHORING_GUIDE.md` (append after current §13).

- [ ] **Step 1:** Add a new section. Draft content (tighten to house voice):

````markdown
## 14. Driving a real daemon or system service

§13 covers a real *external* service you only AUTHENTICATE against. This
section covers a local **daemon/system service the SUT itself controls** —
Docker, a launchd/systemd unit, Apple `container`'s apiserver, a database
server. The contract under test is the SUT's *control path*: does `mytool up`
bring a down daemon to ready, and does `mytool <verb>` fail cleanly when it's
down. That means the section STOPS and STARTS a real service on the operator's
machine — so it is **always `MANUAL_SECTIONS` + Apple/OS-gated + self-skipping**
(don't surprise someone mid-work) and it **restores the service to its starting
state at the end**.

Shape (down-path → ladder → real start → poll → assert):

```zsh
# BUDGET_SECONDS=300            # a cold daemon start can take 10–30s+
# Guard: required CLI present + this is the right backend/OS, else SKIP 0.
command -v <svc-cli> >/dev/null 2>&1 || { skip "§N: <svc> not installed"; exit 0; }

was_up=false; svc_ready && was_up=true        # remember, to restore later

# Phase 1 — stop, assert the SUT's NON-INTERACTIVE down path is clean.
cap 25 <svc-cli> stop
poll_until 'svc_ready' '' 15 || true          # wait until genuinely down
OUT=$(<SUT> <verb> </dev/null 2>&1); rc=$?     # piped stdin ⇒ non-TTY branch
verify "down: clean exit 1, not a crash"       "[[ $rc -eq 1 ]]"
verify "down: no stack trace"                  "! print -r -- \"\$OUT\" | grep -qE 'at .*:[0-9]+|Uncaught'"
verify "down: names the service + how to start" "print -r -- \"\$OUT\" | grep -qiE 'not running|<svc> .* start'"

# Phase 2 — interactive ladder drives the REAL start (needs a pty → term-a).
term_a_start "$SECTION_SLUG" <SUT> <verb>
term_a_answer "$SECTION_SLUG" "[Ss]tart it now" "y" 30 \
  && pass "ladder offered start; accepted" || { fail "no prompt"; ...; }

# Wait on the PERSISTENT pane LOG (not the live pane — §10 race), dual-signal.
pane_log="$SCRIPT_DIR/logs/${SECTION_NUM}-${SECTION_SLUG}-pane.log"
poll_until "grep -qF 'No items found' '$pane_log'" \
           "grep -qiE 'did not become ready|could not' '$pane_log'" 120

# Restore.
svc_ready || cap 25 <svc-cli> start
```

Five rules, each cost a real debugging session this provenance run:

1. **Cap every daemon-control call (`cap N …`).** `<svc> start/stop/status`
   can HANG when the daemon is unhealthy (blocks on an internal "testing
   access" probe). Without a hard cap one wedged call eats the whole budget and
   the runner looks dead. `cap` (lib/control.zsh) runs the command, kills it at
   N seconds, returns 124 on timeout. This is the per-COMMAND analogue of the
   per-section `alarm` budget. (Hard-timeout rule: never let a system command
   block forever.)

2. **The down-path assertion uses piped stdin so the SUT takes its
   NON-interactive branch.** `<SUT> <verb> </dev/null` ⇒ `isTTY` false ⇒ the
   tool prints guidance + exits non-zero WITHOUT prompting. That is the
   scriptable contract. The interactive ladder (phase 2) needs the opposite — a
   real pty — which is why it goes through `term_a_start`, never a pipe.

3. **Assert the POST-CONDITION (service responds), never the launcher's exit
   code or stdout.** A `start`/`up` command may exit non-zero or print a
   scary-but-cosmetic error while the daemon comes up fine moments later (see
   §8 rule 18 + LEARNINGS). Prove readiness by polling the SUT's own readiness
   check (`<svc> status` exit 0, a successful `<SUT> <verb>`), not by grepping
   the launcher's output for the absence of an error. A well-written SUT already
   does this internally — your test should mirror it.

4. **Restore the service to its starting state.** Record `was_up` at entry;
   on exit, bring the daemon back if you stopped it. A smoke section that leaves
   the operator's Docker/daemon down is a footgun even when it PASSES.

5. **Self-skip when the backend/OS doesn't match.** Resolve the SUT's actual
   backend (env → settings file → default) and `skip … ; exit 0` when this
   section's target service isn't the active one. An Apple-only daemon section
   must no-op on a Docker machine, not fail.

Reference implementation: itb's
`engine-preflight/steps/08-apple-live-autodrive.zsh` (auto-driven, Apple-only)
and `07-live-engine-ladder.zsh` (operator-paused, backend-agnostic).
````

- [ ] **Step 2:** Verify the cross-references (§8 rule 18, §10 race) match the
  numbers you actually assign in Tasks 3 + 5. Fix forward-refs after those
  tasks land.

---

## Task 3: AUTHORING_GUIDE §15 — manual section taxonomy (paused vs auto-driven)

**Files:** Modify `payload/AUTHORING_GUIDE.md`.

- [ ] **Step 1:** Add §15. The skill documents `pause` (operator does a thing
  by hand) and `MANUAL_SECTIONS` (excluded from the no-arg run) but never names
  the two DISTINCT manual shapes this session used. Draft:

````markdown
## 15. Two kinds of manual section

A `MANUAL_SECTIONS` entry is excluded from the no-arg run — but there are two
very different reasons a section is manual, and they're authored differently.

**(a) Operator-paused.** A step a human MUST perform or eyeball — a GUI action
(VS Code Remote-SSH connect), a physical device, a judgment call. Use `pause
"<headline>" "<body>"` (returns 0/1/2 = confirm/fail/skip, reads `/dev/tty`).
The runner blocks until the operator acts. Backend-agnostic; the operator
supplies the environment. Example: itb engine-preflight §07 — operator stops
their own engine, the script then drives the recovery.

**(b) Auto-driven manual.** Fully scripted end to end — NO human keystrokes —
but excluded from the no-arg run because it MUTATES shared machine state
(stops a real daemon, removes a real image, rebuilds from cold). It's "manual"
in the run-it-deliberately sense, not the human-in-the-loop sense. It must
self-skip when its precondition (right OS/backend, CLI present) is absent, and
restore state at the end. Example: itb engine-preflight §08 — stops the real
Apple daemon, drives the ladder via `term_a_answer`, polls the pane log,
restarts the daemon, all unattended.

Choose (b) over (a) whenever the action is CLI-scriptable. Auto-driven sections
are repeatable, fast, and don't depend on operator attention — the only reason
to keep a human in the loop is a step no CLI can perform. (a) is a fallback for
genuinely unscriptable steps, not the default for "this touches real state".

Both still log to `$RUN_LOG` and obey the same budget/keep-on-fail machinery.
````

- [ ] **Step 2:** Add one row of guidance to §6 or the §1 mental model pointing
  at §15 so authors discover the taxonomy when they reach for `MANUAL_SECTIONS`.

---

## Task 4: The fast-exit pane-log race — decision gate + fix

**Files:** Modify `payload/lib/term-a.zsh` and/or `payload/AUTHORING_GUIDE.md`
§10; maybe `payload/lib/README.md` + a test.

**Problem (itb LEARNINGS #140):** `term_a_pane_grep`/`term_a_answer` grep the
LIVE pane via `tmux capture-pane`. A SUT that exits faster than the 2s poll
interval takes its pane down before the grep runs — the success signal is lost,
the section false-fails. The persistent `logs/<NN>-<slug>-pane.log` (written by
`term_a_start`'s `tmux pipe-pane`) survives. The fix used in itb was: poll the
pane LOG FILE, not the live pane, for the post-exit completion signal.

- [ ] **Step 1 — DECISION GATE.** Choose one (default: **A**, lowest surface):
  - **A (doc-only):** Add a §10 rule "for a signal the SUT prints just before
    exiting, grep the persistent pane LOG (`logs/<NN>-<slug>-pane.log`), not
    `term_a_pane_grep` (live pane) — a fast exit removes the live pane before
    the poll fires." Show the `poll_until "grep -qF … '$pane_log'" …` idiom.
    No code change. Cheapest; the §14 example already uses it.
  - **B (new helper):** Add `term_a_pane_log_grep "<slug>" "<regex>" [timeout]`
    to `term-a.zsh` that polls the persistent log file with the same signature
    as `term_a_pane_grep`. Needs a `lib/README.md` row + a unit test. Pick this
    only if the idiom recurs enough to be worth a named primitive.

  Recommend A unless, while drafting §14, the raw `poll_until grep pane_log`
  idiom appears 3+ times — then B pays for itself.

- [ ] **Step 2 (if A):** Add the §10 rule. Done.
- [ ] **Step 2 (if B):** Add the helper (mirror `term_a_pane_grep`, swap
  `tmux capture-pane` for `grep … "$SCRIPT_DIR/logs/${SECTION_NUM}-${slug}-pane.log"`),
  add the README row, add `tests/term-a-pane-log-grep.test.ts` (drive a
  fast-exiting fake SUT that prints a sentinel then exits in <1s; assert the
  helper still finds it where `term_a_pane_grep` would miss it).

---

## Task 5: New hard rules (§8) + grep-gate checks (§9)

**Files:** Modify `payload/AUTHORING_GUIDE.md`.

- [ ] **Step 1:** Append to §8 (continue the numbering — next is 16+). Draft:

  - **N. Cap every hang-prone system command with `cap <secs> …`.** Daemon/
    service control verbs (`start`/`stop`/`status`), network probes, and
    anything that can block on an unhealthy backend must run under `cap` (a
    wedged call otherwise eats the section budget and the runner looks hung).
    `cap` returns 124 on timeout — treat that as a failure signal.
    (Originating: an Apple `container system stop` blocked ~2min on a sick
    apiserver during itb §08 authoring; an uncapped background+`sleep` made it
    worse.)

  - **N+1. Assert the post-condition, not the launcher's exit code or output.**
    A `start`/`up`/`enable` command can exit non-zero or print a real-looking
    error and still leave the service fully functional (idempotency races, a
    verification probe that fires before the service settles). NEVER assert "the
    launcher printed no error" — that pathologizes normal output and false-fails
    a healthy system. Assert the END STATE: the readiness check passes, the
    SUT's real verb works. (Originating: itb §08 asserted the absence of an XPC
    error line that `container system start` prints on EVERY invocation — even a
    warm, healthy daemon — so the assertion false-failed a working service.
    LEARNINGS #141. This is the over-correction twin of rule 14's too-loose
    success check: rule 14 = don't poll success-only; this = don't forbid a
    cosmetic error. Both reduce to: key on the genuine post-condition.)

- [ ] **Step 2:** Append to §9 grep gate. Add a check that flags a `verify`
  asserting the ABSENCE of an error string in a launcher's output near a
  daemon/start command — the §141 anti-pattern. Keep it heuristic + low
  false-positive; example:

  ```sh
  # NN. Anti-pattern: asserting NO error in a start/launcher's output
  #     (a launcher can print a cosmetic error on a healthy service — assert the
  #     post-condition instead). Flags `verify "... no error ..." "! ... grep ...
  #     (Error|XPC|internalError) ..."` near a start/up/enable call. Heuristic —
  #     confirm each hit by hand.
  grep -nE 'verify .*(no error|printed NO|without error).*grep' "$F"
  ```

  If this proves too noisy on the existing reference sections, downgrade to a
  prose warning in §14 rule 3 and drop the grep check. Note the decision in the
  commit.

- [ ] **Step 3:** Re-run the EXISTING grep gate (§9) against the skill's own
  reference/template step files to be sure the new check doesn't false-positive
  on shipped examples.

---

## Task 6: LEARNINGS entries (this repo)

**Files:** Modify `.session-continuity/LEARNINGS.md`.

- [ ] **Step 1:** Add a new section `## Authoring real-system smoke sections`
  (these are skill-authoring learnings, distinct from the existing
  shell/bun-test/scaffolder sections). Add 5 entries — follow the repo's
  existing entry style (`### #N — <title> (date)`, terse, with an
  "Originating:" provenance line citing the itb consumer):

  1. **`container system start` exits 1 with a cosmetic XPC error even on a
     healthy daemon — assert the post-condition, not the launcher output.**
     (itb LEARNINGS #141.) The general skill rule: a launcher's exit/stdout is a
     proxy; the service's readiness is the invariant.
  2. **A daemon-control command can HANG; wrap it in a per-command hard cap.**
     The per-section `alarm` budget is too coarse — it fails the whole section
     after minutes; `cap` fails the one wedged call in seconds with a 124.
  3. **The live tmux pane is destroyed when the SUT exits; poll the persistent
     pane LOG for a just-before-exit signal.** (itb #140.)
  4. **Auto-driven manual ≠ operator-paused manual** — name the two shapes; pick
     auto-driven whenever the action is CLI-scriptable; both go in
     `MANUAL_SECTIONS` for different reasons.
  5. **An unquoted heredoc in a shim runs its backticks/`$()` against the
     operator's real environment at author time.** (itb #137 — a `<<SHIM`
     heredoc executed a `` `docker info` `` comment against the real docker and
     baked the output into the shim. Use `<<'SHIM'` quoted; interpolate only an
     explicit header line.) Also note the zsh-specific twin (itb #138): `printf
     %q` is not portable to zsh — use `print -r --`. These bite anyone authoring
     a hermetic PATH-shim section (the §01–06 pattern), so they belong in the
     skill's wisdom even though the shim pattern itself is already implied.

- [ ] **Step 2:** Update the LEARNINGS footer (`*Last entry: …*` + the next-N
  numbering note) per this repo's convention.

---

## Task 7: Tests + version bump + ship

**Files:** `tests/control-cap.test.ts` (new), `package.json` +
`.claude-plugin/plugin.json` (version), `.session-continuity/SESSION_PRIMER.md`.

- [ ] **Step 1:** Write `tests/control-cap.test.ts` — drive `cap` against
  `fixtures/fake-sut.zsh` (or a `sleep 5` command) under a 1s cap: assert it
  returns 124 and kills the child within ~1s (not 5s). And a fast command under
  a 10s cap: assert it returns the command's real rc and does not wait. Mirror
  the existing `tests/control.test.ts` structure.

- [ ] **Step 2:** `bun test` green + `bunx tsc --noEmit` clean + the
  `shellcheck.test.ts` gate passes over the edited `control.zsh`/`term-a.zsh`.

- [ ] **Step 3:** Version bump. This is a feature (new `cap` helper + guide
  sections) → minor bump `0.5.0 → 0.6.0` in BOTH `package.json` and
  `.claude-plugin/plugin.json` (keep them in lockstep — they are the version
  source `skill_version` reads). Consumers re-pull the lib via `smoke-add`'s
  version-gated sync (#21, v0.5.0 mechanism), so the new `cap` reaches itb on
  its next `smoke-add`.

- [ ] **Step 4:** Refresh `.session-continuity/SESSION_PRIMER.md` (current-state
  entry + test count + `git log` block — note the repo's #3 learning: the
  primer log block can't include the SHA of the commit shipping it; regenerate
  the block to PRIOR HEAD and let the next session reconcile, OR refresh it in a
  follow-up as that repo's convention dictates). Stage primer in the SAME commit
  as the change.

- [ ] **Step 5:** Branch `feat/NN-daemon-manual-smoke-learnings` (check
  `gh pr list` for the next PR number first — this repo's convention runs the
  branch number = PR number). Commit, push, open PR, squash-merge per repo
  convention. After merge: re-pull the lib into itb
  (`/smoke-add` from the itb repo, or the documented sync path) so itb's
  `engine-preflight` runner gets `cap` as a shared helper instead of its
  current section-local `ep_cap`.

---

## Self-review checklist (run before opening the PR)

- [ ] Nothing re-documents the already-covered list (scope gate at top).
- [ ] §14/§15 cross-references resolve to the real section/rule numbers.
- [ ] The new grep-gate check does not false-positive on shipped reference
      sections (Task 5 Step 3).
- [ ] `cap` is in `control.zsh` (already-synced file) — no new lib FILE, so no
      `lib-sync.zsh`/`smoke-init.zsh` cp-list edit (LEARNINGS #1 trap avoided).
      If you DID add a file, you MUST edit the cp list + add a sync test.
- [ ] Version bumped in both `package.json` AND `.claude-plugin/plugin.json`.
- [ ] itb's `ep_cap` can be retired in favor of the shared `cap` (note it as a
      follow-up on the itb side — do NOT edit itb in this PR).

---

## Provenance (source material in the itb repo)

- itb `docs/superpowers/smoke-tests/engine-preflight/steps/08-apple-live-autodrive.zsh`
  — the auto-driven daemon section (reference for §14).
- itb `…/steps/07-live-engine-ladder.zsh` — operator-paused variant (§15a).
- itb `.session-continuity/LEARNINGS.md` #137 (unquoted-heredoc shim), #138
  (zsh no `printf %q`), #139 (shim must honor probe order), #140 (live-pane
  grep race), #141 (cosmetic launcher error — assert post-condition).
- itb `src/preflight.ts` `startAndWait` — the SUT-side pattern §14 rule 3
  mirrors (poll readiness, ignore the launcher's exit code).
