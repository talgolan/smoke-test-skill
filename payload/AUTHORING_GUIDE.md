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
3. Append `"NN-<slug>"` to the `ALL_SECTIONS` array in `<topic>/run.zsh`.
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
| `wait_for_port` | `wait_for_port <port> [timeout]` | Polls 127.0.0.1:port for a LISTEN. Returns 0/1. |
| `term_a_start` | `term_a_start "<slug>" <cmd> [args...]` | Detached tmux pty session. Use for any TTY-required SUT command. |
| `term_a_wait_port` | `term_a_wait_port <port> [timeout]` | Same as `wait_for_port` but on the active tmux session, with diagnostics on fail. |
| `term_a_pane_grep` | `term_a_pane_grep "<slug>" "<regex>" [timeout]` | Polls the pane buffer for a regex match. |
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
3. **`verify` for gates, `run` for info.** `verify` increments fail counters and decides exit code; `run` just logs. Don't use `run` for assertions — failures get silently swallowed.
4. **Hooks are optional.** Runners MUST work if `.smokerc` doesn't define `pre_run`, `post_run`, or `reset_cmd`. The runner uses `typeset -f` to test; never `set -u`-explode on missing hooks.
5. **Stash outside `pdir`.** If you stash anything, the stash dir lives at `$pdir.stash` (sibling), not `$pdir/stash` (child). Otherwise `rm -rf $pdir` in Teardown destroys the stash. (Originating: a smoke run destroyed the operator's real `~/.claude/plugins/` because the stash was a child of pdir.)
6. **Never blanket-delete shared host state.** If a section writes into `~/.<anything-the-user-also-uses>` (e.g., `~/.ssh/known_hosts`, `~/.config/foo`), stash + restore in Teardown. Don't `rm -rf ~/.config/foo` outright.
7. **Background processes inside containers need `nohup ... & disown`.** Bare `&` dies on the parent shell's `exit` (SIGHUP). PM2-managed apps survive because PM2 reparents to PID 1; manual `&` does not.
8. **Drift / image-rebuild tests rebuild the SUT after editing source resources.** If the SUT bakes resources at compile time (Bun's `import ... with { type: "text" }`, Go's `embed`, Rust's `include_str!`), editing the resource file alone has no effect on the running binary. Step pattern: edit resource → rebuild via `BUILD_CMD` → invoke SUT.

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

# 6. zsh -n syntax check
zsh -n "$F" && echo "syntax OK"
```

Hits on 1, 2, 3, or 5 → fix. Hits on 4 → confirm the long sleep is intentional + add a comment explaining why. Check 6 must succeed.

---

## 10. When a smoke run fails

In order of cost:

1. **Read the structured `$RUN_LOG`.** Every `verify`, `run`, and `pass`/`fail` is timestamped and prefixed. Search for `FAIL` first, then read 20 lines of context above each.
2. **Re-run a single section:** `./run.zsh NN`. Iterates faster than the full run.
3. **Reproduce a failed `verify` manually.** Copy the `cmd` string from `$RUN_LOG` (after `$ `) and paste at your shell prompt. The same `eval` semantics apply.
4. **Inspect tmux pane logs.** `<topic>/logs/<NN>-<slug>-pane.log` captures the SUT's stdout/stderr inside any `term_a_start`-spawned session, even if the session died fast.
5. **If a step is genuinely slow,** raise `BUDGET_SECONDS` for that step (top-of-file comment), not globally. Document the reason on the same line.
6. **Suspect environment, not test:** check `.smokerc` (`cat`); rebuild the SUT (`cd $SUT_REPO && $BUILD_CMD`); verify `PREFLIGHT_TOOLS` are installed (`./run.zsh` prints them on every run).

---

## 11. Adding a new primitive

If a helper is broadly useful (any SUT could need it), add to `<install-path>/lib/`. Otherwise drop a project-specific helper in `<topic>/lib/<topic>-helpers.zsh` and source it from `<topic>/run.zsh` after `lib/` (so it can extend or override base helpers).

Examples:
- Generic (goes in `lib/`): `wait_for_unix_socket`, `assert_json_field`.
- Project-specific (goes in `<topic>/lib/`): `assert_my_apps_health_endpoint`, `parse_my_custom_log_format`.

When adding to `lib/`: add a row to `lib/README.md`, expose the helper as a top-level function (no `local` for the function name), document required env vars at the top.
