import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const SKILL_ROOT = join(import.meta.dir, "..");
const CONTROL = join(SKILL_ROOT, "payload", "lib", "control.zsh");

const TIMEOUT = 30_000;

// Run a zsh snippet with control.zsh sourced. See control.test.ts for the
// rationale (log.zsh deliberately NOT sourced).
function runControl(snippet: string, env: Record<string, string> = {}) {
  return spawnSync("zsh", ["-c", `source '${CONTROL}'\n${snippet}`], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

test(
  "cap returns 124 and kills the child when the command exceeds the cap",
  () => {
    const start = Date.now();
    const r = runControl(`cap 1 sleep 5; echo "rc=$?"`);
    const elapsed = Date.now() - start;
    expect(r.stdout).toContain("rc=124");
    // Killed at ~1s (+ up to 1s TERM→KILL grace), not the full 5s sleep.
    expect(elapsed).toBeLessThan(4000);
  },
  TIMEOUT
);

test(
  "cap returns the command's real rc and does not wait when it finishes fast",
  () => {
    const start = Date.now();
    const r = runControl(`cap 10 sh -c 'exit 3'; echo "rc=$?"`);
    const elapsed = Date.now() - start;
    expect(r.stdout).toContain("rc=3");
    // Returned as soon as the command exited, not after the 10s cap.
    expect(elapsed).toBeLessThan(5000);
  },
  TIMEOUT
);

test(
  "cap returns 0 for a fast successful command",
  () => {
    const r = runControl(`cap 10 true; echo "rc=$?"`);
    expect(r.stdout).toContain("rc=0");
  },
  TIMEOUT
);

test(
  "cap passes the command's stdout through to the caller",
  () => {
    const r = runControl(`OUT=$(cap 10 echo hello-from-cap); echo "out=$OUT"`);
    expect(r.stdout).toContain("out=hello-from-cap");
  },
  TIMEOUT
);

test(
  "cap clamps a sub-1s cap up to 1s rather than killing instantly",
  () => {
    // secs<1 is clamped to 1, so a 0-second cap still lets a fast command run.
    const r = runControl(`cap 0 true; echo "rc=$?"`);
    expect(r.stdout).toContain("rc=0");
  },
  TIMEOUT
);
