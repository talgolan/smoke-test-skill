import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, chmodSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");
const FAKE_SUT = join(SKILL_ROOT, "tests", "fixtures", "fake-sut.zsh");

test("scaffolded runner against fake SUT runs 01-example to PASS", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });

    const sutBin = join(work, "fake-sut.zsh");
    copyFileSync(FAKE_SUT, sutBin);
    chmodSync(sutBin, 0o755);

    const initRes = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "demo",
      "--non-interactive",
      "--sut-bin", sutBin,
      "--sut-repo", work,
      "--build-cmd", ":",
      "--preflight", "tmux jq",
    ], { cwd: work, encoding: "utf8" });
    expect(initRes.status).toBe(0);

    const runRes = spawnSync(
      join(work, "smoke", "demo", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8", env: { ...process.env, BUDGET_SECONDS: "10" } }
    );
    if (runRes.status !== 0) {
      console.log("STDOUT:", runRes.stdout);
      console.log("STDERR:", runRes.stderr);
    }
    expect(runRes.status).toBe(0);
    expect(runRes.stdout).toMatch(/01-example\s+PASS/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
