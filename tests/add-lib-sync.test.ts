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
const ADD = join(SKILL_ROOT, "scripts", "smoke-add.zsh");
const PLUGIN_JSON = join(SKILL_ROOT, ".claude-plugin", "plugin.json");

// Current skill version — the value smoke-add should sync up to.
const CURRENT = JSON.parse(readFileSync(PLUGIN_JSON, "utf8")).version as string;

/**
 * Seed a target project with a .smokerc-bearing install dir whose lib/ holds a
 * stamped .skill-version but is otherwise empty (so we can detect a sync by the
 * presence of a real lib file like control.zsh). Returns paths.
 */
function seed(versionStamp: string | null) {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-sync-"));
  mkdirSync(join(work, ".git"), { recursive: true });
  const installAbs = join(work, "smoke");
  mkdirSync(join(installAbs, "lib"), { recursive: true });
  writeFileSync(join(installAbs, ".smokerc"), "SUT_BIN=/tmp/foo\n");
  if (versionStamp !== null) {
    writeFileSync(join(installAbs, "lib", ".skill-version"), `${versionStamp}\n`);
  }
  return { work, installAbs };
}

function runAdd(work: string, topic: string) {
  return spawnSync("zsh", [ADD, "--install-path", "smoke", "--topic", topic], {
    cwd: work,
    encoding: "utf8",
  });
}

test("stale .skill-version triggers a lib re-copy and stamp bump", () => {
  const { work, installAbs } = seed("0.2.0");
  try {
    const res = runAdd(work, "auth");
    expect(res.status).toBe(0);
    // Lib re-copied: control.zsh (added in v0.4.0) now present.
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(true);
    // Stamp bumped to current.
    expect(
      readFileSync(join(installAbs, "lib", ".skill-version"), "utf8").trim(),
    ).toBe(CURRENT);
    // Sync line announced on stdout.
    expect(res.stdout).toMatch(/synced shared lib 0\.2\.0/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("current .skill-version leaves lib untouched, no sync line", () => {
  const { work, installAbs } = seed(CURRENT);
  try {
    // Marker file inside lib/ — a full sync would NOT delete it (cp is additive),
    // so we instead detect no-sync by absence of control.zsh (never copied here).
    const res = runAdd(work, "auth");
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(false);
    expect(res.stdout).not.toMatch(/synced shared lib/);
    // Stamp unchanged.
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
    const res = runAdd(work, "auth");
    expect(res.status).toBe(0);
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(true);
    expect(
      readFileSync(join(installAbs, "lib", ".skill-version"), "utf8").trim(),
    ).toBe(CURRENT);
    expect(res.stdout).toMatch(/synced shared lib 0\.0\.0/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test("installed newer than skill is not downgraded; stderr note emitted", () => {
  const { work, installAbs } = seed("9.9.9");
  try {
    const res = runAdd(work, "auth");
    expect(res.status).toBe(0);
    // Not clobbered: control.zsh never copied, stamp preserved.
    expect(existsSync(join(installAbs, "lib", "control.zsh"))).toBe(false);
    expect(
      readFileSync(join(installAbs, "lib", ".skill-version"), "utf8").trim(),
    ).toBe("9.9.9");
    expect(res.stderr).toMatch(/installed lib \(9\.9\.9\) newer than skill/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
