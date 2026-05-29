import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const ADD = join(SKILL_ROOT, "scripts", "smoke-add.zsh");

test("smoke-add refuses if topic dir exists", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    writeFileSync(join(work, ".smokerc"), "SUT_BIN=/tmp/foo\n");
    mkdirSync(join(work, "demo"), { recursive: true });

    const res = spawnSync("zsh", [ADD, "--topic", "demo"], { cwd: work, encoding: "utf8" });
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/exists/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
