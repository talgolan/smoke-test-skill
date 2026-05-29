import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const ADD = join(SKILL_ROOT, "scripts", "smoke-add.zsh");

test("smoke-add replaces {{TOPIC}} everywhere; no leftovers", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    writeFileSync(join(work, ".smokerc"), "SUT_BIN=/tmp/foo\n");

    const res = spawnSync("zsh", [ADD, "--topic", "myfeat"], { cwd: work, encoding: "utf8" });
    expect(res.status).toBe(0);

    for (const f of ["myfeat/run.zsh", "myfeat/README.md", "myfeat/steps/01-example.zsh"]) {
      const content = readFileSync(join(work, f), "utf8");
      expect(content).not.toContain("{{TOPIC}}");
      expect(content).toContain("myfeat");
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
