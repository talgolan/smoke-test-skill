import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const SKILL_ROOT = join(import.meta.dir, "..");
const CONTROL = join(SKILL_ROOT, "payload", "lib", "control.zsh");

// Run a zsh snippet with control.zsh sourced. log.zsh is NOT sourced, so the
// snippet must define any pass/fail/log it references (smoke_keep_on_fail reads
// the FAIL_COUNT variable directly, which we set explicitly here).
function runControl(snippet: string, env: Record<string, string> = {}) {
  return spawnSync("zsh", ["-c", `source '${CONTROL}'\n${snippet}`], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

test("poll_until returns 0 immediately when success-cmd is already true", () => {
  const r = runControl(`poll_until 'true' 'false' 5 1; echo "rc=$?"`);
  expect(r.stdout).toContain("rc=0");
});

test("poll_until returns 2 when the failure-cmd fires", () => {
  // success never true, failure immediately true → fast abort with rc 2
  const r = runControl(`poll_until 'false' 'true' 5 1; echo "rc=$?"`);
  expect(r.stdout).toContain("rc=2");
});

test("poll_until returns 1 on timeout when neither fires", () => {
  const start = Date.now();
  const r = runControl(`poll_until 'false' 'false' 2 1; echo "rc=$?"`);
  const elapsed = Date.now() - start;
  expect(r.stdout).toContain("rc=1");
  // Honored the timeout rather than returning instantly.
  expect(elapsed).toBeGreaterThanOrEqual(1500);
});

test("poll_until success wins even when failure-cmd is also true", () => {
  // both true on the first tick → success checked first → rc 0
  const r = runControl(`poll_until 'true' 'true' 5 1; echo "rc=$?"`);
  expect(r.stdout).toContain("rc=0");
});

test("poll_until with empty failure-cmd polls success only", () => {
  const r = runControl(`poll_until 'true' '' 5 1; echo "rc=$?"`);
  expect(r.stdout).toContain("rc=0");
});

test("smoke_keep_on_fail false when SMOKE_KEEP_ON_FAIL unset (even with failures)", () => {
  const r = runControl(
    `FAIL_COUNT=3; smoke_keep_on_fail && echo KEEP || echo TEARDOWN`
  );
  expect(r.stdout).toContain("TEARDOWN");
});

test("smoke_keep_on_fail false when set but no failures", () => {
  const r = runControl(
    `FAIL_COUNT=0; smoke_keep_on_fail && echo KEEP || echo TEARDOWN`,
    { SMOKE_KEEP_ON_FAIL: "1" }
  );
  expect(r.stdout).toContain("TEARDOWN");
});

test("smoke_keep_on_fail true when set AND a failure was recorded", () => {
  const r = runControl(
    `FAIL_COUNT=1; smoke_keep_on_fail && echo KEEP || echo TEARDOWN`,
    { SMOKE_KEEP_ON_FAIL: "1" }
  );
  expect(r.stdout).toContain("KEEP");
});

test("smoke_keep_on_fail tolerates unset FAIL_COUNT", () => {
  // FAIL_COUNT defaults to 0 via ${FAIL_COUNT:-0} — must not error under set -u.
  const r = runControl(
    `set -u; smoke_keep_on_fail && echo KEEP || echo TEARDOWN`,
    { SMOKE_KEEP_ON_FAIL: "1" }
  );
  expect(r.status).toBe(0);
  expect(r.stdout).toContain("TEARDOWN");
});
