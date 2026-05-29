import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync, existsSync, readFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");

let work: string;

beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  // Pretend it's a git repo so walk-up boundary is well-defined.
  mkdirSync(join(work, ".git"), { recursive: true });
});
afterAll(() => rmSync(work, { recursive: true, force: true }));

test("smoke-init on empty dir produces lib/, AUTHORING_GUIDE.md, .smokerc, <topic>/run.zsh", () => {
  const res = spawnSync("zsh", [INIT,
    "--install-path", "smoke",
    "--topic", "demo",
    "--non-interactive",
    "--sut-bin", "/tmp/fake-sut",
    "--sut-repo", "/tmp",
    "--build-cmd", ":",
  ], { cwd: work, encoding: "utf8" });

  if (res.status !== 0) {
    console.log("STDOUT:", res.stdout);
    console.log("STDERR:", res.stderr);
  }
  expect(res.status).toBe(0);

  const installDir = join(work, "smoke");
  expect(existsSync(join(installDir, "lib", "env.zsh"))).toBe(true);
  expect(existsSync(join(installDir, "lib", "log.zsh"))).toBe(true);
  expect(existsSync(join(installDir, "lib", "term-a.zsh"))).toBe(true);
  expect(existsSync(join(installDir, "lib", "pause.zsh"))).toBe(true);
  expect(existsSync(join(installDir, "lib", "README.md"))).toBe(true);
  expect(existsSync(join(installDir, "AUTHORING_GUIDE.md"))).toBe(true);
  expect(existsSync(join(installDir, ".smokerc"))).toBe(true);
  expect(existsSync(join(installDir, "demo", "run.zsh"))).toBe(true);
  expect(existsSync(join(installDir, "demo", "steps", "01-example.zsh"))).toBe(true);
  expect(existsSync(join(installDir, "demo", "README.md"))).toBe(true);

  const rc = readFileSync(join(installDir, ".smokerc"), "utf8");
  expect(rc).toContain('SUT_BIN="/tmp/fake-sut"');
  expect(rc).toContain('SUT_REPO="/tmp"');
  expect(rc).toContain('BUILD_CMD=":"');

  const runZsh = readFileSync(join(installDir, "demo", "run.zsh"), "utf8");
  expect(runZsh).not.toContain("{{TOPIC}}");
  expect(runZsh).toContain('"01-example"');

  const exampleStep = readFileSync(join(installDir, "demo", "steps", "01-example.zsh"), "utf8");
  expect(exampleStep).not.toContain("{{TOPIC}}");
  expect(exampleStep).toContain("demo §");
});
