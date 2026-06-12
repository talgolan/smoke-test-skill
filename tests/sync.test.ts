import { test, expect } from "bun:test";
import {
  mkdtempSync,
  rmSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const SYNC = join(SKILL_ROOT, "scripts", "smoke-sync.zsh");
const PLUGIN_JSON = join(SKILL_ROOT, ".claude-plugin", "plugin.json");

const CURRENT = JSON.parse(readFileSync(PLUGIN_JSON, "utf8")).version as string;

// Seed a target project: a .git boundary + a .smokerc-bearing install dir whose
// lib/ holds only a stamped .skill-version (so a sync is detectable by the
// appearance of a real lib file like control.zsh).
function seed(versionStamp: string | null) {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-synccmd-"));
  mkdirSync(join(work, ".git"), { recursive: true });
  const installAbs = join(work, "smoke");
  mkdirSync(join(installAbs, "lib"), { recursive: true });
  writeFileSync(join(installAbs, ".smokerc"), "SUT_BIN=/tmp/foo\n");
  if (versionStamp !== null) {
    writeFileSync(join(installAbs, "lib", ".skill-version"), `${versionStamp}\n`);
  }
  return { work, installAbs };
}

function runSync(work: string, args: string[] = ["--install-path", "smoke"]) {
  return spawnSync("zsh", [SYNC, ...args], { cwd: work, encoding: "utf8" });
}

test("stale .skill-version triggers a lib re-copy and stamp bump", () => {
  const { work, installAbs } = seed("0.2.0");
  try {
    const res = runSync(work);
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(true);
    expect(existsSync(join(installAbs, "AUTHORING_GUIDE.md"))).toBe(true);
    expect(
      readFileSync(join(installAbs, "lib", ".skill-version"), "utf8").trim(),
    ).toBe(CURRENT);
    expect(res.stdout).toMatch(/synced shared lib 0\.2\.0/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("current .skill-version is a no-op with an 'already current' message", () => {
  const { work, installAbs } = seed(CURRENT);
  try {
    const res = runSync(work);
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(false);
    expect(res.stdout).not.toMatch(/synced shared lib/);
    expect(res.stdout).toMatch(/already current/);
    expect(
      readFileSync(join(installAbs, "lib", ".skill-version"), "utf8").trim(),
    ).toBe(CURRENT);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("missing .skill-version is treated as 0.0.0 and triggers sync", () => {
  const { work, installAbs } = seed(null);
  try {
    const res = runSync(work);
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(true);
    expect(res.stdout).toMatch(/synced shared lib 0\.0\.0/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("installed newer than skill is not downgraded; stderr note emitted", () => {
  const { work, installAbs } = seed("9.9.9");
  try {
    const res = runSync(work);
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(false);
    expect(
      readFileSync(join(installAbs, "lib", ".skill-version"), "utf8").trim(),
    ).toBe("9.9.9");
    expect(res.stderr).toMatch(/installed lib \(9\.9\.9\) newer than skill/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("walk-up discovery finds the default install dir with no --install-path", () => {
  // Seed at the default docs/superpowers/smoke-tests path so the .git-boundary
  // fallback resolves it, then run from a nested cwd with no args.
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-syncwalk-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const installAbs = join(work, "docs", "superpowers", "smoke-tests");
    mkdirSync(join(installAbs, "lib"), { recursive: true });
    writeFileSync(join(installAbs, ".smokerc"), "SUT_BIN=/tmp/foo\n");
    writeFileSync(join(installAbs, "lib", ".skill-version"), "0.2.0\n");
    const nested = join(work, "src", "deep");
    mkdirSync(nested, { recursive: true });

    const res = spawnSync("zsh", [SYNC], { cwd: nested, encoding: "utf8" });
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/synced shared lib 0\.2\.0/);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(true);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("no .smokerc anywhere fails with a clear error", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-syncnone-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const res = spawnSync("zsh", [SYNC], { cwd: work, encoding: "utf8" });
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/no \.smokerc found/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
