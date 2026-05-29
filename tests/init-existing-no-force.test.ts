import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");

test("smoke-init refuses non-empty install path; no files written", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, "smoke"), { recursive: true });
    writeFileSync(join(work, "smoke", "preexisting.txt"), "do not touch\n");

    const res = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "demo",
      "--non-interactive",
      "--sut-bin", "/tmp/x", "--sut-repo", "/tmp", "--build-cmd", ":",
    ], { cwd: work, encoding: "utf8" });

    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/not empty/);

    const remaining = readdirSync(join(work, "smoke"));
    expect(remaining).toEqual(["preexisting.txt"]);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
