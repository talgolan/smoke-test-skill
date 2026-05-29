import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const ADD = join(SKILL_ROOT, "scripts", "smoke-add.zsh");

test("smoke-add walk-up halts at .git boundary, doesn't pick up parent .smokerc", () => {
  const outer = mkdtempSync(join(tmpdir(), "smoke-test-skill-outer-"));
  try {
    // Outer has a .smokerc (simulates an unrelated parent project).
    writeFileSync(join(outer, ".smokerc"), "# parent\n");
    // Inner has its own .git boundary, no .smokerc.
    const inner = join(outer, "inner");
    mkdirSync(join(inner, ".git"), { recursive: true });

    const res = spawnSync("zsh", [ADD, "--topic", "demo"], { cwd: inner, encoding: "utf8" });
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/no .smokerc found/);
  } finally {
    rmSync(outer, { recursive: true, force: true });
  }
});
