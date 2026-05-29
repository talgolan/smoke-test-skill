import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");

test("runner fails with BUILD_CMD hint when SUT_BIN not executable", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });

    const initRes = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "demo",
      "--non-interactive",
      "--sut-bin", "/nonexistent/binary",
      "--sut-repo", work,
      "--build-cmd", "make build",
      "--preflight", "tmux",
    ], { cwd: work, encoding: "utf8" });
    expect(initRes.status).toBe(0);

    const runRes = spawnSync(
      join(work, "smoke", "demo", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8" }
    );
    expect(runRes.status).not.toBe(0);
    expect(runRes.stderr + runRes.stdout).toMatch(/not executable/);
    expect(runRes.stderr + runRes.stdout).toMatch(/make build/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
