import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, copyFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");
const FAKE_SUT = join(SKILL_ROOT, "tests", "fixtures", "fake-sut.zsh");

test("runner fails with named missing preflight tool", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const sutBin = join(work, "sut.zsh");
    copyFileSync(FAKE_SUT, sutBin);
    chmodSync(sutBin, 0o755);

    const initRes = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "demo",
      "--non-interactive",
      "--sut-bin", sutBin, "--sut-repo", work, "--build-cmd", ":",
      "--preflight", "this-tool-does-not-exist-1234567",
    ], { cwd: work, encoding: "utf8" });
    expect(initRes.status).toBe(0);

    const runRes = spawnSync(
      join(work, "smoke", "demo", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8" }
    );
    expect(runRes.status).not.toBe(0);
    expect(runRes.stderr + runRes.stdout).toMatch(/this-tool-does-not-exist-1234567/);
    expect(runRes.stderr + runRes.stdout).toMatch(/missing/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
