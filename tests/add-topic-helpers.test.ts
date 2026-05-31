import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, chmodSync, copyFileSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");
const FAKE_SUT = join(SKILL_ROOT, "tests", "fixtures", "fake-sut.zsh");

// Initialize a real install (lib/ + .smokerc) with one topic, mirroring
// runner-smoke.test.ts. Returns the work dir; the topic lives at
// <work>/smoke/<topic>/.
function initInstall(topic: string): string {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  mkdirSync(join(work, ".git"), { recursive: true });
  const sutBin = join(work, "fake-sut.zsh");
  copyFileSync(FAKE_SUT, sutBin);
  chmodSync(sutBin, 0o755);
  const res = spawnSync("zsh", [INIT,
    "--install-path", "smoke",
    "--topic", topic,
    "--non-interactive",
    "--sut-bin", sutBin,
    "--sut-repo", work,
    "--build-cmd", ":",
    "--preflight", "tmux jq",
  ], { cwd: work, encoding: "utf8" });
  expect(res.status).toBe(0);
  return work;
}

test("smoke-add/init scaffolds a topic-local helper stub with TOPIC substituted", () => {
  const work = initInstall("myfeat");
  try {
    const helper = join(work, "smoke", "myfeat", "lib", "myfeat-helpers.zsh");
    expect(existsSync(helper)).toBe(true);
    const content = readFileSync(helper, "utf8");
    expect(content).not.toContain("{{TOPIC}}");
    expect(content).toContain("myfeat");
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("run.zsh auto-sources <topic>/lib/*.zsh in BOTH the top-level and the per-section sub-shell", () => {
  const work = initInstall("myfeat");
  try {
    const runZsh = readFileSync(join(work, "smoke", "myfeat", "run.zsh"), "utf8");
    // The topic-lib glob source must appear twice: once at top level, once
    // inside the alarm-wrapped step sub-shell. A single occurrence is the
    // footgun this wiring exists to prevent (helper visible at top level but
    // not inside the step → `command not found` only when the step runs).
    const matches = runZsh.match(/\$SCRIPT_DIR\/lib\/['"]?\*\.zsh/g) ?? [];
    expect(matches.length).toBe(2);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("a function defined in the topic helper is visible inside a step sub-shell", () => {
  const work = initInstall("myfeat");
  try {
    writeFileSync(
      join(work, "smoke", "myfeat", "lib", "myfeat-helpers.zsh"),
      "#!/usr/bin/env zsh\nmyfeat_marker() { print -r -- 'HELPER-VISIBLE'; }\n",
    );
    writeFileSync(
      join(work, "smoke", "myfeat", "steps", "01-example.zsh"),
      [
        "#!/usr/bin/env zsh",
        "set -u",
        "emulate -L zsh",
        'sect "myfeat helper visibility"',
        "RUN_OUT=$(myfeat_marker)",
        'verify "topic helper callable in step" "[[ \\"$RUN_OUT\\" == HELPER-VISIBLE ]]"',
        "(( FAIL_COUNT > 0 )) && exit 1 || exit 0",
      ].join("\n"),
    );
    const res = spawnSync(
      join(work, "smoke", "myfeat", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8", env: { ...process.env, BUDGET_SECONDS: "10" } },
    );
    if (res.status !== 0) {
      console.log("STDOUT:", res.stdout);
      console.log("STDERR:", res.stderr);
    }
    // The step calls the helper and gates on its output via `verify`; a PASS
    // line proves the function resolved inside the sub-shell. A `command not
    // found` (helper not sourced in the sub-shell) would fail the verify.
    expect(res.stdout + res.stderr).toContain("PASS  topic helper callable in step");
    expect(res.stdout + res.stderr).not.toContain("command not found");
    expect(res.status).toBe(0);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
