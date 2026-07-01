# Smoke-Test Authoring Guide

Read this once before authoring any step file. Every rule here has a real failure attached — none are speculative.

---

## 1. What this is

This directory holds an executable smoke-test framework. A "smoke run" drives a built binary (`$SUT_BIN`) end-to-end against the real environment (real Docker, real ports, real filesystem) and asserts behavior. Each *runner* lives in its own directory (`<topic>/`) and is composed of *sections* — discrete, self-contained steps that prove one specific contract.

File map (after `/smoke-init` and one `/smoke-add` call):

```
<install-path>/
├── .smokerc            # SUT_BIN, SUT_REPO, BUILD_CMD, hooks, etc.
├── lib/                # shared zsh primitives (don't edit per-runner)
├── AUTHORING_GUIDE.md  # this file
└── <topic>/            # one runner
    ├── run.zsh         # controller; iterates ALL_SECTIONS
    ├── steps/NN-*.zsh  # one file per section
    └── logs/           # run-<ts>.log, <NN>-<slug>-pane.log
```

---

## 2. The mental model

- A **section** is the unit of test. One section = one fenced behavior.
- Sections are **self-contained**. A section never relies on artifacts produced by another section. Setup creates what it needs; Teardown removes it.
- `run.zsh` orchestrates. It sources `.smokerc`, validates `$SUT_BIN`, runs preflight, executes each section in a sub-shell wrapped by an `alarm`-based budget, and emits a summary table.
- `lib/` provides primitives (`verify`, `run`, `log`, `pass`, `fail`, `wait_for_port`, tmux helpers). Don't edit it per-runner; project-specific helpers go in `<topic>/lib/<topic>-helpers.zsh`.
- `.smokerc` configures (see `lib/env.zsh` for the validated schema). Hooks (`pre_run`, `post_run`, `reset_cmd`) are optional.
- Step files do the actual work. Each one runs in a sub-shell and inherits `$SUT_BIN`, `$SUT_REPO`, `$SMOKE_ROOT`, `$SECTION_SLUG`, `$SECTION_NUM`, `$RUN_LOG`.

---

## 3. Authoring a new section

1. Create `<topic>/steps/NN-<slug>.zsh` where `NN` is the next sequential number, two-digit.
2. Make it executable: `chmod +x <topic>/steps/NN-<slug>.zsh` (optional; `run.zsh` sources it, doesn't exec it).
3. Append `"NN-<slug>"` to the `ALL_SECTIONS` array in `<topic>/run.zsh`. If the section mutates shared machine state or needs a human, also add it to `MANUAL_SECTIONS` — see §15 for the two kinds of manual section and how each is authored.
4. Use `01-example.zsh` as the structural template. Replace the example checks with the real ones.
5. Run the section in isolation while authoring: `./run.zsh NN`.
6. Run the grep gate (§9) before committing.

### Worked example

A new runner for an `httpd` SUT, §2 "serves on port 8080":

```zsh
#!/usr/bin/env zsh
# httpd §2: serves on configured port
set -u
emulate -L zsh

pdir="$SMOKE_ROOT/httpd-s${SECTION_NUM}"
sect "httpd §${SECTION_NUM}: serves on port 8080"

# Setup
mkdir -p "$pdir"
echo 'hello' > "$pdir/index.html"
[[ -f "$pdir/index.html" ]] && pass "setup: index.html written" || { fail "setup"; exit 1; }

# Spawn SUT in tmux (needs a TTY for graceful Ctrl-C teardown)
term_a_start "${SECTION_SLUG}" "$SUT_BIN" --root "$pdir" --port 8080
term_a_wait_port 8080 30 || exit 1

# Real behavior assertion
RUN_OUT=$(curl -s http://127.0.0.1:8080/index.html)
verify "served body matches" "[[ \"\$RUN_OUT\" == \"hello\" ]]"

# Teardown
term_a_close "${SECTION_SLUG}"
rm -rf "$pdir"
exit 0
```

---

## 4. The primitives

| Helper | Signature | Use |
|---|---|---|
| `verify` | `verify "label" "shell-cond"` | Gate step. `eval`s the cond; logs output; emits PASS or FAIL. Returns 0/1 for caller use. |
| `run`    | `run "label" "cmd"`           | Informational. Logs cmd + output + rc. Never marks pass/fail on its own. |
| `log` / `info` / `warn` / `err` | one arg | Plain log lines, with severity prefix. |
| `sect`   | one arg | Emits a `=== <header> ===` divider. Use once per section. |
| `pass` / `fail` / `skip` | one arg (label) | Explicit result emission. `pass`/`fail` increment counters. `skip` doesn't. |
| `wait_for_port` | `wait_for_port <port> [timeout]` | Polls 127.0.0.1:port for a LISTEN. Returns 0/1. **Use this instead of `nc -z` — BSD `nc` and GNU `nc` disagree on flags (BSD: `-z host port`, GNU: `-zv host port`); same script breaks crossing macOS↔Linux.** |
| `poll_until` | `poll_until <success-cmd> <failure-cmd> <timeout> [interval]` | Poll BOTH a success and a failure signal. Returns `0` (success), `2` (failure signal fired — abort fast), `1` (timeout). Pass `""` for failure-cmd to poll success-only (discouraged — see §8 rule 14). |
| `smoke_keep_on_fail` | `smoke_keep_on_fail` | True when this section failed — DEFAULT preserves diagnostic state; `SMOKE_KEEP_ON_FAIL=0` forces teardown-on-failure. Guard teardown with it. Pair with `keep_on_fail_notice <handle>...`. See §10. |
| `term_a_start` | `term_a_start "<slug>" <cmd> [args...]` | Detached tmux pty session. Use for any TTY-required SUT command. |
| `term_a_wait_port` | `term_a_wait_port <port> [timeout]` | Same as `wait_for_port` but on the active tmux session, with diagnostics on fail. |
| `term_a_pane_grep` | `term_a_pane_grep "<slug>" "<regex>" [timeout]` | Polls the pane buffer for a regex match. |
| `term_a_send` | `term_a_send "<slug>" "<keys>"` | Type a line into the pty + Enter. Empty string → bare Enter (accept a default). For scripting an interactive SUT's prompts. |
| `term_a_answer` | `term_a_answer "<slug>" "<prompt-regex>" "<reply>" [timeout]` | Wait for `<prompt-regex>` in the pane, then send `<reply>`+Enter. Returns 1 on timeout. See §12. |
| `term_a_close` | `term_a_close "<slug>"` | `tmux kill-session`; sends SIGHUP to spawned process tree. |
| `pause`  | `pause "<headline>" "<body>"` | Operator action prompt. Returns 0/1/2 for confirm/fail/skip. |

### `RUN_OUT` capture pattern

`verify` declares `local out` internally. If your step file also declares `out=...`, your value gets shadowed during the `eval`. Convention: capture into `RUN_OUT` for caller variables.

```zsh
# WRONG — out shadowed by verify's local out
out=$("$SUT_BIN" status)
verify "running" "echo \$out | grep -q running"

# RIGHT
RUN_OUT=$("$SUT_BIN" status)
verify "running" "echo \$RUN_OUT | grep -q running"
```

---

## 5. Per-section project dirs

Convention: every section gets its own dir at `$SMOKE_ROOT/<topic>-sN/` where `N == ${SECTION_NUM}`.

- Setup creates it (`mkdir -p`).
- Teardown removes it (`rm -rf`).
- Don't use `/tmp/` — host OS purges it, denylists may forbid it, race-prone.
- Don't use `/private/tmp/`, `/var/`, `/etc/`, `/usr/`, `/`, home-dir root, or `/Volumes/` — many are blocked by SUT-side path denylists or are dangerous to `rm -rf`.

If a section needs to stash existing host state (e.g., user's `~/.config/<thing>` while testing it), stash to a dir *outside* `pdir`:

```zsh
stash="$pdir.stash"  # NOT $pdir/stash — rm -rf $pdir would destroy it
[[ -d "$HOME/.config/foo" ]] && cp -R "$HOME/.config/foo" "$stash"
# ... do the test ...
rm -rf "$pdir"
[[ -d "$stash" ]] && { rm -rf "$HOME/.config/foo"; mv "$stash" "$HOME/.config/foo"; }
```

---

## 6. Budgets

Default: 30 s per section, enforced by `perl -e 'alarm(N); exec'` around the step's sub-shell. A timed-out step is killed and marked `TIMEOUT` in the summary.

Per-step override (top of step file):
```zsh
#!/usr/bin/env zsh
# BUDGET_SECONDS=120
# Reason: this section pulls a 200MB image on a cold cache.
```

`BUDGET_SECONDS=N` env var overrides for the whole run. `0` disables enforcement (debugging only — never commit `BUDGET_SECONDS=0` in `.smokerc`).

When to override:
- Image build / pull / large download.
- Multi-step container init (compose-up, healthcheck wait).

When NOT to override:
- A genuinely slow check — split into multiple smaller sections instead. Smaller sections are easier to debug.
- "It sometimes runs slow on my laptop" — fix the flake or add an explicit `wait_for_port`/poll, don't paper over with a bigger budget.

### Budget vs history

Once a section has 5+ PASS entries in `.history.jsonl`, set `# BUDGET_SECONDS` to roughly `1.5 × p95(history)`. `run.zsh`'s pre-run banner prints both numbers; its drift warning fires when `p95 ≥ budget`. Avoid the temptation to set the budget to `p95 + 10s` — sections occasionally take 2× median for legitimate reasons (cold cache, slow CI runner), and a tight budget produces flaky TIMEOUTs without surfacing real bugs.

`.history.jsonl` is committed by default — diff-per-run is one appended line per section, capped to 50 PASS + 10 non-PASS rows per section after each run. Authors who do not want history in repo can `.gitignore` `<topic>/.history.jsonl` per-runner.

---

## 7. Self-contained step files

A section MUST work whether it's run as part of `./run.zsh`, in isolation as `./run.zsh NN`, or out of order with other sections. That means:

- **Idempotent setup.** `mkdir -p` (not `mkdir`). `rm -rf` before recreating, then `mkdir -p`. Never assume a parent dir exists.
- **No dependence on prior sections' artifacts.** If §3 needs §1 to have run, fold §1's setup into §3 too. Cheaper to redo than to debug a phantom-skip.
- **Absolute paths everywhere.** Step sub-shells inherit env, but `cd` doesn't persist between separate sub-shells. If you need a path, spell it out: `$SMOKE_ROOT/<topic>-sN/file`, never `./file`.
- **No reliance on cwd.** `pbpaste | bash`, `tmux send-keys`, and the runner's own sub-shell wrapping all drop the parent shell's cwd.

---

## 8. Hard rules

Each rule has a real failure attached. Provenance in parentheses.

1. **Absolute paths everywhere.** Sub-shells drop cwd. (Originating: a smoke runner ran fine standalone but broke under `pbpaste | bash` in a paste-and-run smoke; the cd never persisted.)
2. **Use `RUN_OUT` not `out`.** `verify` declares `local out`; it shadows your `out` during `eval`. (Originating: a §6 conflict-detection check returned PASS even when `RUN_OUT=""` because `out` was empty.)
3. **`verify` for gates, `run` for info.** `verify` increments `FAIL_COUNT` (and prints PASS/FAIL); `run` just logs. Don't use `run` for assertions — failures get silently swallowed. **`verify` does NOT set the step's exit code** — it only bumps the counter. A step that ends with a bare `exit 0` therefore reports PASS to `run.zsh` even after a `verify` FAILed. You MUST end the step with the FAIL_COUNT-exit tail (rule 19). (This is a common, dangerous miswrite — the gate lies on verify-only failures.)
4. **Hooks are optional.** Runners MUST work if `.smokerc` doesn't define `pre_run`, `post_run`, or `reset_cmd`. The runner uses `typeset -f` to test; never `set -u`-explode on missing hooks.
5. **Stash outside `pdir`.** If you stash anything, the stash dir lives at `$pdir.stash` (sibling), not `$pdir/stash` (child). Otherwise `rm -rf $pdir` in Teardown destroys the stash. (Originating: a smoke run destroyed the operator's real `~/.claude/plugins/` because the stash was a child of pdir.)
6. **Never blanket-delete shared host state.** If a section writes into `~/.<anything-the-user-also-uses>` (e.g., `~/.ssh/known_hosts`, `~/.config/foo`), stash + restore in Teardown. Don't `rm -rf ~/.config/foo` outright.
7. **Background processes inside containers need `nohup ... & disown`.** Bare `&` dies on the parent shell's `exit` (SIGHUP). PM2-managed apps survive because PM2 reparents to PID 1; manual `&` does not.
8. **Drift / image-rebuild tests rebuild the SUT after editing source resources.** If the SUT bakes resources at compile time (Bun's `import ... with { type: "text" }`, Go's `embed`, Rust's `include_str!`), editing the resource file alone has no effect on the running binary. Step pattern: edit resource → rebuild via `BUILD_CMD` → invoke SUT.
9. **Hooks and helpers must use `command rm` / `command mv`.** A user's interactive aliases (`alias rm='rm -i'`, `alias mv='mv -i'`) inherit into `pre_run` / `post_run` / `reset_cmd` and any helper sourced by `.smokerc`. Bare `rm` / `mv` then prompt for confirmation and the run hangs. `command <bin>` bypasses both functions and aliases. (Originating: a `reset_cmd` helper hung indefinitely in non-interactive context; the user's `rm -i` alias was waiting for stdin.)
10. **Filter PATH by exact dir, not by binary-name substring.** When a section needs to hide a binary from PATH (proving fallback behavior), `dirname $(which <bin>)` first, then strip that exact path component. `grep -v <bin-name>` on PATH components silently misses generic dirs (`~/.bun/bin/portless` doesn't contain "portless" as a substring; the filter matches nothing and the binary stays on PATH).
11. **Don't assert on a JSON path that varies by tool version.** Tools rewrite their config schemas across releases (`jq '.plugins | keys'` returns `[]` even when the plugin is installed because the new version writes a different file/key). Assert via multiple paths and accept any: directory existence, `find` for the name, AND `grep -q` for a substring of the canonical config file. (Originating: a plugin-isolation §3 assertion failed on a real PASS because claude rewrote `installed_plugins.json` shape.)
12. **Renumbered sections must rename their pdir to match.** If you renumber §3 → §2, the step file's `pdir="$SMOKE_ROOT/<topic>-s${SECTION_NUM}"` updates automatically (it uses `$SECTION_NUM`), but any HARD-CODED `~/smoke/<topic>-3/` paths in the file body don't. The grep gate (§9 check 7) flags `<topic>-N/` paths that don't match the section's filename number.
13. **Reset GLOBAL (non-workspace) SUT state in setup, not just `pdir`.** The per-section `pdir` model only isolates filesystem state under `$SMOKE_ROOT`. If the SUT also writes state that lives OUTSIDE the workspace — docker images/containers (global to the daemon), `npm -g` / `brew` global installs, system services, a shared cache or registry, a daemon's own database — clearing `pdir` (or even an isolated `$HOME`/config dir) is NOT enough. A stale global artifact from an unrelated prior run is silently reused and masks the behavior under test. Enumerate the SUT's global side-effects and reset the relevant ones in Setup (e.g. `docker rmi -f <sut-image>:latest` before a build-and-run section). (Originating: an itb smoke ran against a stale `itb-final:latest` left by an earlier session with a different harness selection; the container had no node, so `npm install` in poststart failed — but the test pointed at the symlink logic, not the stale image, until `docker inspect <name> --format '{{.Config.Image}}'` revealed which image actually started. Clearing the SUT's isolated `$HOME` did nothing because the image chain is global to the docker daemon.)

14. **Poll BOTH a success and a failure signal — never success only.** A loop that waits for the success artifact to appear and nothing else burns the entire timeout on every failure, and can't tell "slow" from "broken". Watch the failure signal too (an error sidecar file, a `failed-*.txt` marker, a non-zero status the SUT records) and abort the instant it fires, with the real reason. Use the `poll_until <success> <failure> <timeout>` helper (returns 0/2/1 for success/failure/timeout). (Originating: an itb §3 waited only for `~/.local/bin/sf` to appear; when poststart's `npm install` failed, the section sat through its full 120s budget and reported "did not install" instead of "install FAILED — here's the log". Watching `failed-harnesses.txt` aborts in ~2s with the cause.)

15. **`verify` / `poll_until` `eval` their command string in the HOST shell — `$VAR` expands host-side, even inside an inner `docker exec`.** `verify "label" "cmd"` runs `eval "$cmd"` in the runner's host zsh (`lib/log.zsh`). Every `$HOME`, `$VAR`, and backtick in that string — including ones buried inside an inner `docker exec <name> bash -lc "... $HOME ..."` — is expanded by the HOST before the string ever reaches the container. `$HOME` becomes the host home, not `/home/<container-user>`; a host-unset var becomes empty. Rule: in any string passed to `verify`/`poll_until` that targets the container, use **fully-literal container paths** (`/home/assistant/.local/bin/sf`), never `$HOME` or host-resolved vars. Assign the literal to a local (`SF=/home/assistant/.local/bin/sf`) and reference that. (Same family as the eval-interpolation footgun: an itb §3 `sf` call resolved `$HOME` to the operator's Mac home and the in-container path silently pointed nowhere.)

16. **Size the container/service ready-wait against a COLD build, not a warm one.** Readiness timeouts that pass on a warm cache (image already built, deps already installed) silently fail the first time the section runs cold — a from-scratch image build (apt + a runtime toolchain can be ~2 min; slower on some backends) blows past a 120s wait that was tuned on warm runs. Size the ready-wait against the section's `BUDGET_SECONDS` ceiling (e.g. 480s wait under a 600s budget), not the warm-run time. If the build and the ready-wait share a budget, the wait must leave headroom for the assertions that follow. (Originating: an itb §3 ready-wait of 120s passed every warm re-run and failed on the first cold-cache run, where the harness+user image stages alone took longer than the wait.)

17. **Cap every hang-prone system command with `cap <secs> …`.** Daemon/service control verbs (`start`/`stop`/`status`), network probes, and anything that can block on an unhealthy backend must run under `cap` (lib/control.zsh). `cap` returns the command's real rc, or 124 if it had to kill the command at the cap — treat 124 as a failure signal. This is the per-COMMAND analogue of the per-section `alarm` budget: a wedged call otherwise eats the whole section budget and the runner looks hung, failing after minutes instead of seconds. (Originating: an Apple `container system stop` blocked ~2 min on a sick apiserver during itb §08 authoring; the uncapped call wedged the runner.)

18. **Assert the post-condition, not the launcher's exit code or output.** A `start`/`up`/`enable` command can exit non-zero or print a real-looking error and still leave the service fully functional — an idempotency race, or a verification probe that fires before the service settles. NEVER assert "the launcher printed no error": that pathologizes normal output and false-fails a healthy system. Assert the END STATE instead — the readiness check passes, the SUT's real verb works. This is the over-correction twin of rule 14 (don't poll success-only); both reduce to: key on the genuine post-condition, never a proxy. (Originating: itb §08 asserted the absence of an XPC error line that `container system start` prints on EVERY invocation — even a warm, healthy daemon — so the assertion false-failed a working service. itb LEARNINGS #141.)

19. **End every step with the FAIL_COUNT-exit tail — a bare `exit 0` makes the gate LIE.** `run.zsh` decides a section's PASS/FAIL from the step's EXIT CODE, but `verify` only increments `FAIL_COUNT` (rule 3) — it does not touch the exit code. So a step that does its assertions and then ends `exit 0` reports PASS even when a `verify` FAILed. The last line of every step that runs any `verify` MUST be:
    ```zsh
    (( FAIL_COUNT > 0 )) && exit 1 || exit 0
    ```
    Early `exit 1` on a hard prerequisite failure (setup couldn't build, daemon down) is fine and independent — this rule is about the FINAL line after the assertion block. A step whose only failures are `verify` failures and which ends bare `exit 0` is the single most dangerous miswrite: it converts a real regression into a green check. (Originating: an itb build-egress runner ended all four steps `exit 0`; §03 logged a `verify` FAIL yet the section reported PASS — the gate silently swallowed it. The bug was only caught because a human re-read the per-assertion lines, not the section verdict.)

---

## 9. Grep gate (run before committing a step file)

Save as `<install-path>/scripts/gate.sh` or paste into a shell. Every check must produce zero hits.

```sh
F=<topic>/steps/NN-<slug>.zsh

# 1. Bare relative path that should be absolute
grep -nE '\b(cd|cat|rm|mkdir|cp|mv) +(\.|\.\.|[^/$"][a-zA-Z0-9_.-]*\.[a-z]+)' "$F" \
  | grep -v '^\s*#'

# 2. `out=` capture in step body — should be `RUN_OUT=`
grep -nE '^\s*out=\$' "$F"

# 3. Bare `&` for background process (no nohup)
grep -nE '\b(node|python3?|sleep|nc|server)\b[^&]*&\s*$' "$F" | grep -v 'nohup'

# 4. `# wait Ns` inside a fenced block (should be a prose pause, but step
#    files are zsh — flag any `sleep` longer than 5s without a comment)
grep -nE '^\s*sleep [0-9]{2,}' "$F"

# 5. /tmp/ as project dir (redirects for log files are OK)
grep -nE '\B/tmp/[a-zA-Z]' "$F" | grep -vE '>[[:space:]]*/tmp/|/tmp/[a-zA-Z._-]+\.(log|out|err|sha)'

# 6. nc -z probe — use wait_for_port (BSD/GNU nc flags disagree)
grep -nE '\bnc -z' "$F"

# 7. Hard-coded section-dir number that doesn't match the file's NN prefix
fname=$(basename "$F")          # e.g. 03-foo.zsh
nn=${fname%%-*}                 # 03
topic=$(basename "$(dirname "$(dirname "$F")")")   # parent's parent dir name
grep -nE "${topic}-[0-9]+" "$F" | grep -vE "${topic}-${nn}\\b|${topic}-\\\$\\{SECTION_NUM\\}|${topic}-s\\\$\\{SECTION_NUM\\}"

# 8. $HOME (or other host-resolved var) inside a docker/container exec string —
#    expands HOST-side via verify/poll_until's eval (§8 rule 15). Use a literal
#    container path instead.
grep -nE '(docker|container) exec.*\$HOME' "$F"

# 9. Anti-pattern: asserting NO error in a launcher's output (§8 rule 18). A
#    start/up/enable can print a cosmetic error on a healthy service — assert the
#    post-condition instead. Heuristic; confirm each hit by hand.
grep -nE 'verify .*(no error|printed NO|without error).*grep' "$F"

# 10. zsh -n syntax check
zsh -n "$F" && echo "syntax OK"

# 11. Step runs verify() but never propagates FAIL_COUNT to the exit code
#     (§8 rule 19). A bare final `exit 0` makes the section report PASS even
#     after a verify FAILed — the gate lies. Flag any step that calls verify
#     but has no `FAIL_COUNT` guard anywhere.
if grep -qE '^\s*verify ' "$F" && ! grep -qE 'FAIL_COUNT' "$F"; then
  echo "FAIL: $F runs verify but never checks FAIL_COUNT — add the rule-19 exit tail"
fi
```

Hits on 1, 2, 3, 5, 6, 7, or 8 → fix. Hits on 4 → confirm the long sleep is intentional + add a comment explaining why. Hits on 9 → confirm each by hand; it's heuristic (§8 rule 18 — a launcher's cosmetic error must not be forbidden). Check 10 must succeed.

---

## 10. When a smoke run fails

### Operating a long run

While a run is in flight, poll the structured log at the **per-section interval printed in `run.zsh`'s pre-run banner**. The banner shows `poll every Ns` for each section, computed from `ceil(p95/4)` clamped to [15, 120] seconds. Sections without history poll at 15 s.

```sh
tail -n 50 <topic>/logs/run-<latest>.log
```

For sections that spawn the SUT in tmux, also tail the pane log: `<topic>/logs/<NN>-<slug>-pane.log`. If a tail at `p95 + 30s` shows no progress and the section's p50 is well under that, kill the run (`pkill -f run.zsh`, plus `tmux kill-session -t <slug>` for any active term-a sessions) rather than waiting out `BUDGET_SECONDS`. The budget is an upper bound, not a health check.

### Preserving evidence on failure

Sections tear down on EVERY exit by default (`rm -rf $pdir`, `docker rm`, kill the tmux session). That is correct for a passing run, but on a FAILURE it destroys the one thing you need: the live state that holds the cause. When the failure follows an expensive setup (a cold image build, a real install, a multi-step wizard), re-running to reproduce costs that whole setup again.

Guard teardown with `smoke_keep_on_fail`: **by default**, when a section records a failure it skips teardown and prints the live handles to probe — preserving the evidence is the default because destroying it on failure repeatedly cost a full re-setup per root cause. A PASSING section always tears down. Set `SMOKE_KEEP_ON_FAIL=0` to force teardown-on-failure (CI, or an unattended sweep where leftovers would accumulate).

```zsh
sect "§${SECTION_NUM}-teardown"
if smoke_keep_on_fail; then
  keep_on_fail_notice "container: $NAME" "itb_home: $itb_home" "login.out: $login_out"
  exit 1
fi
term_a_close "$slug"
docker rm -f "$NAME" >>"$RUN_LOG" 2>&1 || true
rm -rf "$pdir"
exit 0
```

Two companion rules:

- **Surface the diagnostic INTO `$RUN_LOG` in the failure branch BEFORE any teardown** — matters most under `SMOKE_KEEP_ON_FAIL=0`. Dump the relevant log (redacted; see §13) at the point of failure; never delete a capture file and then assert on it. A diagnostic that only lives in `$pdir` is gone the moment teardown runs.
- A preserved failure leaves global state alive (containers, isolated `$HOME`s). Clean it up by hand once you're done probing — the next run's §13-rule-13 global reset will also clear it, but don't rely on that across unrelated runners. (The smoke-mutation gate blocks you from killing/exec-ing it while a run is still active — wait for the run to exit, then clean.)

### After a failure

In order of cost:

1. **Read the structured `$RUN_LOG`.** Every `verify`, `run`, and `pass`/`fail` is timestamped and prefixed. Search for `FAIL` first, then read 20 lines of context above each.
2. **Re-run a single section:** `./run.zsh NN`. Iterates faster than the full run.
3. **Reproduce a failed `verify` manually.** Copy the `cmd` string from `$RUN_LOG` (after `$ `) and paste at your shell prompt. The same `eval` semantics apply.
4. **Inspect tmux pane logs.** `<topic>/logs/<NN>-<slug>-pane.log` captures the SUT's stdout/stderr inside any `term_a_start`-spawned session, even if the session died fast.

   **For a completion signal a SUT prints just before exiting, grep the persistent pane LOG — not `term_a_pane_grep`.** `term_a_pane_grep` polls the LIVE pane and requires `tmux has-session` to be true while it polls. A SUT that prints its result and exits faster than the poll interval takes its session down before the grep fires, so the match is lost and the section false-fails — even though the output definitely appeared. The persistent `logs/<NN>-<slug>-pane.log` (written by `term_a_start`'s `tmux pipe-pane`) survives the session. Poll the file instead, dual-signal, keyed on the EXACT message (a loose alternation can match a path/name echo and pass spuriously):

   ```zsh
   pane_log="$SCRIPT_DIR/logs/${SECTION_NUM}-${SECTION_SLUG}-pane.log"
   for _ in {1..60}; do
     grep -qF '<exact completion string>' "$pane_log" 2>/dev/null && break
     grep -qiE '<failure pattern>'         "$pane_log" 2>/dev/null && break
     sleep 2
   done
   ```

   (Originating: an itb §05 keyed its completion check on `term_a_pane_grep` for `itb list`, which exits immediately after a successful preflight; the session closed before the poll and the section reported "list did not complete" while the pane log plainly contained the success message. itb LEARNINGS #140.)
5. **If a step is genuinely slow,** raise `BUDGET_SECONDS` for that step (top-of-file comment), not globally. Document the reason on the same line.
6. **Suspect environment, not test:** check `.smokerc` (`cat`); rebuild the SUT (`cd $SUT_REPO && $BUILD_CMD`); verify `PREFLIGHT_TOOLS` are installed (`./run.zsh` prints them on every run).

---

## 11. Adding a new primitive

If a helper is broadly useful (any SUT could need it), add to `<install-path>/lib/`. Otherwise drop a project-specific helper in `<topic>/lib/<topic>-helpers.zsh` and source it from `<topic>/run.zsh` after `lib/` (so it can extend or override base helpers).

Examples:
- Generic (goes in `lib/`): `wait_for_unix_socket`, `assert_json_field`.
- Project-specific (goes in `<topic>/lib/`): `assert_my_apps_health_endpoint`, `parse_my_custom_log_format`.

When adding to `lib/`: add a row to `lib/README.md`, expose the helper as a top-level function (no `local` for the function name), document required env vars at the top.

### Topic-local helpers are auto-sourced (both scopes)

`/smoke-add` scaffolds an empty `<topic>/lib/<topic>-helpers.zsh` stub. `run.zsh` sources every `<topic>/lib/*.zsh` file in **two** places: once at top level, and once inside the per-section `alarm`-wrapped sub-shell that actually runs your step. **Both** matter — a helper available at top level but not in the sub-shell throws `command not found` only when the step runs, which is a confusing failure. Because the scaffold wires both, just define your function in the stub and it is visible to every step. If you add a *second* helper file, drop it in `<topic>/lib/` too — the glob picks it up; you do not edit `run.zsh`.

---

## 12. Driving an interactive SUT

Some SUTs prompt during setup (a first-run wizard, a `[Y/n]` confirmation, a multi-choice selector). `pause` is for prompting the *operator*; to answer the *SUT's own* prompts, script them through the pty.

Pattern: spawn the SUT with `term_a_start`, then `term_a_answer` once per prompt — it waits for the prompt text, types the reply, and returns. Finally wait for an explicit **completion signal** before asserting or tearing down.

```zsh
term_a_start "$slug" "$SUT_BIN" init
term_a_answer "$slug" "Backend .docker/container."  ""           # Enter = accept default
term_a_answer "$slug" "Enter harness ids"           "claude sf"

# Wait for the SUT to FINISH — not for the first file it writes.
# Key on a sentinel the SUT writes LAST (here: completedInit:true).
ready=false
for _ in {1..20}; do
  if [[ -f "$cfg" ]] && jq -e '.completedInit == true' "$cfg" >/dev/null 2>&1; then
    ready=true; break
  fi
  sleep 1
done
$ready && pass "init completed" || { fail "init did not complete"; exit 1; }
```

Three rules that each cost a real debugging session:

1. **Wait for the prompt, don't guess timing.** `term_a_answer` polls the pane for the prompt regex. Don't `sleep 3; term_a_send` — prompt latency varies and a blind send races the SUT.
2. **Key completion on the LAST write, never the first.** Multi-step wizards write config in stages. If you tear down (or assert) the moment the first artifact appears, you truncate the SUT mid-write and later stages never land. Find a field/line the SUT emits *last* (a `completedInit` flag, a final "done" banner) and wait for that.
3. **Use a clean shell for the pty when the SUT prompt collides with your login shell.** `term_a_start` inherits your environment; an interactive `zsh` with oh-my-zsh update prompts or `chsh` notices can swallow the first keystroke you send. If that bites, start the session under `bash` (`term_a_start "$slug" bash` then `term_a_send` the command) so no rc-file prompt competes for input.

---

## 13. Testing against a real authenticated service

Some contracts can only be proven against a live, authed external service (a cloud API, an org login, a registry that requires a token). That means a real credential enters the run. Four rules keep it safe and the section honest.

1. **Skip cleanly when the credential source is absent — don't fail.** The credential comes from the operator's own already-authed host state (a CLI keychain, an env var, a token file), never from a secret committed to the repo. If it's not there, `skip` with a one-line "log in on the host first" hint and `exit 0`. A missing host credential is an environment gap, not a SUT bug — failing on it makes the whole run red for everyone who hasn't authed.

   ```zsh
   ORG=$(resolve_host_credential)   # an org alias / username — NOT the secret
   if [[ -z "$ORG" ]]; then
     skip "§${SECTION_NUM}: no connected host org. Log in first, e.g. sf org login web"
     exit 0
   fi
   ```

2. **The secret crosses into the SUT ONLY as an env var — never argv, never a config file the test writes.** Process args (`ps`, `/proc/<pid>/cmdline`) and on-disk config are observable; an env var passed to a single `docker exec -e` is the narrowest channel. Non-secret context (an instance URL, a username, an org alias) is fine to interpolate and log.

   ```zsh
   # token via -e (not argv); $INSTANCE_URL is not secret, safe to interpolate
   docker exec --user assistant -e SVC_TOKEN="$TOKEN" "$NAME" \
     bash -lc "$SVC login --token-from-env --url '$INSTANCE_URL'" >"$out" 2>&1
   ```

3. **The secret must never reach `$RUN_LOG` or the summary.** Capture the SUT's auth output to a file you do NOT `tee` verbatim. On failure, redact before surfacing: `sed -E 's/<secret-pattern>/<REDACTED>/g'` the capture into the log so the diagnostic survives teardown (§10) without leaking the token. Log only the rc and the non-secret context.

4. **Prefer a read-only round-trip for the assertion.** Prove auth worked with a cheap GET that makes no permission assumptions and mutates nothing (list limits, whoami, a metadata read) — not a write. The contract is "the SUT can authenticate and reach the service", which a read proves.

Reference implementation: itb's `sf-harness/steps/03-sf-org-auth.zsh` — extracts a live access token on the host, forwards it via `docker exec -e`, logs in inside the container, asserts `connectedStatus == Connected` + a `list limits` round-trip, redacts org-id tokens on any failure dump, and self-skips when no host org is connected.

---

## 14. Driving a real daemon or system service

§13 covers a real *external* service you only AUTHENTICATE against. This section covers a local **daemon or system service the SUT itself controls** — Docker, a launchd/systemd unit, Apple `container`'s apiserver, a database server. The contract under test is the SUT's *control path*: does `mytool up` bring a down daemon to ready, and does `mytool <verb>` fail cleanly when the daemon is down. That means the section STOPS and STARTS a real service on the operator's machine — so it is **always `MANUAL_SECTIONS` + OS/backend-gated + self-skipping** (don't surprise someone mid-work) and it **restores the service to its starting state at the end**. See §15 for which kind of manual section this is.

Shape (down-path → ladder → real start → poll → restore):

```zsh
# BUDGET_SECONDS=300            # a cold daemon start can take 10–30s+
set -u
emulate -L zsh

# Guard: required CLI present + this is the active backend/OS, else SKIP 0.
command -v <svc-cli> >/dev/null 2>&1 || { skip "§${SECTION_NUM}: <svc> not installed"; exit 0; }

svc_ready() { cap 10 <svc-cli> status >/dev/null 2>&1; }   # cap — a sick daemon hangs
was_up=false; svc_ready && was_up=true                     # remember, to restore

# Phase 1 — stop, assert the SUT's NON-INTERACTIVE down path is clean.
cap 25 <svc-cli> stop
down=false; for _ in {1..15}; do svc_ready || { down=true; break }; sleep 1; done  # wait until DOWN
$down || { fail "could not stop <svc>"; $was_up && cap 25 <svc-cli> start; exit 1; }
RUN_OUT=$("$SUT_BIN" <verb> </dev/null 2>&1); rc=$?         # piped stdin ⇒ non-TTY branch
verify "down: clean exit 1, not a crash"        "[[ $rc -eq 1 ]]"
verify "down: no stack trace"                   "! print -r -- \"\$RUN_OUT\" | grep -qE 'at .*:[0-9]+|Uncaught'"
verify "down: names the service + how to start" "print -r -- \"\$RUN_OUT\" | grep -qiE 'not running|<svc> .* start'"

# Phase 2 — interactive ladder drives the REAL start (needs a pty → term-a).
term_a_start "$SECTION_SLUG" "$SUT_BIN" <verb>
term_a_answer "$SECTION_SLUG" "[Ss]tart it now" "y" 30 || { fail "no prompt"; term_a_close "$SECTION_SLUG"; $was_up && cap 25 <svc-cli> start; exit 1; }

# Wait on the PERSISTENT pane LOG (not the live pane — §10 race), dual-signal.
pane_log="$SCRIPT_DIR/logs/${SECTION_NUM}-${SECTION_SLUG}-pane.log"
done=false
for _ in {1..60}; do
  grep -qF '<exact ready message>' "$pane_log" 2>/dev/null && { done=true; break }
  grep -qiE 'did not become ready|could not' "$pane_log" 2>/dev/null && break
  sleep 2
done
term_a_close "$SECTION_SLUG"
$done && pass "real <svc> started + <verb> completed" || fail "<svc> did not come ready"

# Restore.
svc_ready || cap 25 <svc-cli> start
```

Five rules, each cost a real debugging session in this provenance run:

1. **Cap every daemon-control call with `cap N …`.** `<svc> start`/`stop`/`status` can HANG when the daemon is unhealthy (it blocks on an internal "verifying access" probe). Without a hard cap one wedged call eats the whole section budget and the runner looks dead. `cap` (lib/control.zsh) runs the command, kills it at N seconds, returns 124 on timeout — the per-COMMAND analogue of run.zsh's per-SECTION `alarm`. See §8 rule 17.

2. **The down-path assertion pipes stdin so the SUT takes its NON-interactive branch.** `"$SUT_BIN" <verb> </dev/null` ⇒ `isTTY` false ⇒ the tool prints guidance and exits non-zero WITHOUT prompting. That is the scriptable contract. The interactive ladder (phase 2) needs the opposite — a real pty — which is why it goes through `term_a_start`, never a pipe.

3. **Assert the POST-CONDITION (service responds), never the launcher's exit code or stdout.** A `start`/`up` command may exit non-zero or print a scary-but-cosmetic error while the daemon comes up fine moments later (§8 rule 18). Prove readiness by polling the SUT's own readiness check (`<svc> status` exit 0, or a successful `"$SUT_BIN" <verb>`), not by grepping the launcher's output for the absence of an error. A well-written SUT already polls readiness internally and ignores the launcher's rc — your test should mirror it.

4. **Restore the service to its starting state.** Record `was_up` at entry; on exit, bring the daemon back if you stopped it. A section that leaves the operator's Docker/daemon down is a footgun even when it PASSES.

5. **Self-skip when the backend/OS doesn't match.** Resolve the SUT's actual backend (env → settings file → default) and `skip … ; exit 0` when this section's target service isn't the active one. An Apple-only daemon section must no-op on a Docker machine, not fail.

Reference implementations: itb's `engine-preflight/steps/08-apple-live-autodrive.zsh` (auto-driven, Apple-only — the full cycle unattended) and `07-live-engine-ladder.zsh` (operator-paused, backend-agnostic). See §15 for the difference.

---

## 15. Two kinds of manual section

A `MANUAL_SECTIONS` entry is excluded from the no-arg run — but there are two very different reasons a section is manual, and they're authored differently.

**(a) Operator-paused.** A step a human MUST perform or eyeball — a GUI action (VS Code Remote-SSH connect), a physical device, a judgment call, a daemon whose control is GUI-only (`open -a Docker` has no scriptable "stop"). Use `pause "<headline>" "<body>"` (returns 0/1/2 = confirm/fail/skip, reads `/dev/tty`); the runner blocks until the operator acts. Backend-agnostic — the operator supplies the environment. Example: itb engine-preflight §07 — the operator stops their own engine, the script then drives the recovery.

**(b) Auto-driven manual.** Fully scripted end to end — NO human keystrokes — but excluded from the no-arg run because it MUTATES shared machine state (stops a real daemon, removes a real image, rebuilds from cold). It's "manual" in the run-it-deliberately sense, not the human-in-the-loop sense. It must self-skip when its precondition (right OS/backend, CLI present) is absent, and restore state at the end. Example: itb engine-preflight §08 — stops the real Apple daemon, drives the ladder via `term_a_answer`, polls the pane log, restarts the daemon, all unattended.

Choose (b) over (a) whenever the action is CLI-scriptable: auto-driven sections are repeatable, fast, and don't depend on operator attention. Keep a human in the loop only for a step no CLI can perform — (a) is the fallback for genuinely unscriptable steps, not the default for "this touches real state".

Both still log to `$RUN_LOG` and obey the same budget / keep-on-fail machinery.
