import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const SKILL_ROOT = join(import.meta.dir, "..");
const TERMA = join(SKILL_ROOT, "payload", "lib", "term-a.zsh");

// Source term-a.zsh in a throwaway zsh with a stubbed log() + a tmpdir SCRIPT_DIR,
// then run the given snippet. tmux is required (a preflight tool of the harness).
function runTermA(snippet: string) {
  const pre = [
    "emulate -L zsh",
    "set -u",
    'tmp=$(mktemp -d)',
    'export SCRIPT_DIR="$tmp" RUN_LOG="$tmp/run.log" SECTION_NUM="06"',
    'mkdir -p "$tmp/logs"',
    "log(){ print -r -- \"$@\" | tee -a \"$RUN_LOG\"; }",
    `source '${TERMA}'`,
  ].join("\n");
  return spawnSync("zsh", ["-c", `${pre}\n${snippet}`], { encoding: "utf8" });
}

const haveTmux = spawnSync("tmux", ["-V"], { encoding: "utf8" }).status === 0;
const maybe = haveTmux ? test : test.skip;

maybe("term_a_wait_ready returns 0 the moment the probe passes", () => {
  const r = runTermA([
    "tmux new-session -d -s smoke-r1 'sleep 30' 2>/dev/null",
    'term_a_wait_ready r1 "true" 10; echo "rc=$?"',
    "tmux kill-session -t smoke-r1 2>/dev/null",
  ].join("\n"));
  expect(r.stdout).toContain("rc=0");
});

maybe("term_a_wait_ready returns 2 + surfaces the pane tail when the launch dies", () => {
  const r = runTermA([
    // No session smoke-r2 → launch already dead; pipe-log holds the real error.
    'print -r -- "devbar is not signed in. Run: devbar auth login" > "$tmp/logs/06-r2-pane.log"',
    'term_a_wait_ready r2 "false" 10; echo "rc=$?"',
    // The pane tail is tee'd into $RUN_LOG (not stdout) — surface it to assert.
    'cat "$RUN_LOG"',
  ].join("\n"));
  expect(r.stdout).toContain("rc=2");
  expect(r.stdout).toContain("devbar is not signed in");
});

maybe("term_a_wait_ready returns 1 on a bounded timeout when the session stays alive", () => {
  const r = runTermA([
    "tmux new-session -d -s smoke-r3 'sleep 30' 2>/dev/null",
    "start=$SECONDS",
    'term_a_wait_ready r3 "false" 4; rc=$?',
    'echo "rc=$rc elapsed=$((SECONDS-start))"',
    "tmux kill-session -t smoke-r3 2>/dev/null",
  ].join("\n"));
  expect(r.stdout).toContain("rc=1");
  // Honored the timeout (did not fall through to launch-died fast path).
  const m = r.stdout.match(/elapsed=(\d+)/);
  expect(m).not.toBeNull();
  expect(Number(m![1])).toBeGreaterThanOrEqual(3);
});
