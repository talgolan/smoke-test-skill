import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");

test("runner fails with named key when .smokerc sets SUT_BIN to empty", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });

    const initRes = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "demo",
      "--non-interactive",
      "--sut-bin", "/tmp/x", "--sut-repo", "/tmp", "--build-cmd", ":",
      "--preflight", "tmux",
    ], { cwd: work, encoding: "utf8" });
    expect(initRes.status).toBe(0);

    const rcPath = join(work, "smoke", ".smokerc");
    writeFileSync(rcPath, [
      'SUT_BIN=""',
      'SUT_REPO="/tmp"',
      'BUILD_CMD=":"',
      'PREFLIGHT_TOOLS=(tmux)',
      "",
    ].join("\n"));

    const runRes = spawnSync(
      join(work, "smoke", "demo", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8" }
    );
    expect(runRes.status).not.toBe(0);
    expect(runRes.stderr + runRes.stdout).toMatch(/SUT_BIN.*non-empty|SUT_BIN.*must be/i);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
