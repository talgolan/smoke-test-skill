import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const ADD = join(SKILL_ROOT, "scripts", "smoke-add.zsh");

test("smoke-add --install-path uses explicit dir when .smokerc present", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-ip-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const installRel = "custom/smoke";
    const installAbs = join(work, installRel);
    mkdirSync(installAbs, { recursive: true });
    writeFileSync(join(installAbs, ".smokerc"), "SUT_BIN=/tmp/foo\n");

    const res = spawnSync(
      "zsh",
      [ADD, "--install-path", installRel, "--topic", "auth"],
      { cwd: work, encoding: "utf8" },
    );
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "auth/run.zsh"))).toBe(true);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("smoke-add --install-path errors if .smokerc missing at given path", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-ip-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    mkdirSync(join(work, "custom/smoke"), { recursive: true });

    const res = spawnSync(
      "zsh",
      [ADD, "--install-path", "custom/smoke", "--topic", "auth"],
      { cwd: work, encoding: "utf8" },
    );
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/\.smokerc not found/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("smoke-add walk-up falls back to default install path when halted at .git", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-fb-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const def = join(work, "docs/superpowers/smoke-tests");
    mkdirSync(def, { recursive: true });
    writeFileSync(join(def, ".smokerc"), "SUT_BIN=/tmp/foo\n");

    // Run from repo root — walk-up halts at .git, fallback should kick in.
    const res = spawnSync("zsh", [ADD, "--topic", "fallback"], {
      cwd: work,
      encoding: "utf8",
    });
    expect(res.status).toBe(0);
    expect(existsSync(join(def, "fallback/run.zsh"))).toBe(true);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("smoke-add fallback does not engage when default dir lacks .smokerc", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-fb-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    // default dir exists but no .smokerc inside it
    mkdirSync(join(work, "docs/superpowers/smoke-tests"), { recursive: true });

    const res = spawnSync("zsh", [ADD, "--topic", "ghost"], {
      cwd: work,
      encoding: "utf8",
    });
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/no .smokerc found/);
    expect(res.stderr).toMatch(/--install-path/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
