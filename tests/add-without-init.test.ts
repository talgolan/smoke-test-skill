import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const ADD = join(SKILL_ROOT, "scripts", "smoke-add.zsh");

test("smoke-add without prior init exits 2 with helpful message", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const res = spawnSync("zsh", [ADD, "--topic", "ghost"], { cwd: work, encoding: "utf8" });
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/no .smokerc found/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
