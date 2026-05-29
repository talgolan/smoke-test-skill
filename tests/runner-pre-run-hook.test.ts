import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, copyFileSync, chmodSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");
const FAKE_SUT = join(SKILL_ROOT, "tests", "fixtures", "fake-sut.zsh");

const setup = () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  mkdirSync(join(work, ".git"), { recursive: true });
  const sutBin = join(work, "sut.zsh");
  copyFileSync(FAKE_SUT, sutBin);
  chmodSync(sutBin, 0o755);
  spawnSync("zsh", [INIT,
    "--install-path", "smoke",
    "--topic", "demo",
    "--non-interactive",
    "--sut-bin", sutBin, "--sut-repo", work, "--build-cmd", ":",
    "--preflight", "tmux",
  ], { cwd: work });
  return { work, sutBin };
};

test("pre_run defined in .smokerc is called before sections", () => {
  const { work } = setup();
  try {
    appendFileSync(join(work, "smoke", ".smokerc"),
      "\npre_run() { echo PRE_RAN; return 0; }\n");
    const runRes = spawnSync(
      join(work, "smoke", "demo", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8" }
    );
    expect(runRes.status).toBe(0);
    expect(runRes.stdout).toMatch(/PRE_RAN/);
    expect(runRes.stdout).toMatch(/01-example\s+PASS/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("pre_run returning non-zero aborts the run before sections", () => {
  const { work } = setup();
  try {
    appendFileSync(join(work, "smoke", ".smokerc"),
      "\npre_run() { echo PRE_FAIL >&2; return 1; }\n");
    const runRes = spawnSync(
      join(work, "smoke", "demo", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8" }
    );
    expect(runRes.status).not.toBe(0);
    expect(runRes.stderr + runRes.stdout).toMatch(/PRE_FAIL/);
    expect(runRes.stdout).not.toMatch(/01-example\s+PASS/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
