import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync, existsSync, readFileSync, mkdirSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const HOOK = join(SKILL_ROOT, "payload", "hooks", "smoke-active-gate.sh");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");

// Drive the PreToolUse hook with a Bash tool payload on stdin and a sentinel
// path via SMOKE_SENTINEL_FILE. Returns "deny" | "allow".
function runHook(cmd: string, sentinelFile: string): "deny" | "allow" {
  const payload = JSON.stringify({ tool_input: { command: cmd } });
  const res = spawnSync("bash", [HOOK], {
    input: payload,
    encoding: "utf8",
    env: { ...process.env, SMOKE_SENTINEL_FILE: sentinelFile },
  });
  return res.stdout.includes('"deny"') ? "deny" : "allow";
}

let work: string;
let sentinel: string;

beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), "smoke-gate-"));
  sentinel = join(work, ".smoke-run-active");
});
afterAll(() => rmSync(work, { recursive: true, force: true }));

test("no sentinel → every command is allowed", () => {
  // sentinel absent
  expect(runHook("docker exec foo sh", sentinel)).toBe("allow");
  expect(runHook("pkill -f run.zsh", sentinel)).toBe("allow");
});

test("sentinel active → mutating verbs are denied", () => {
  writeFileSync(sentinel, "pid=1 started=0 runner=x");
  for (const cmd of [
    "docker exec foo sh",
    "container exec foo true",
    "kill -9 123",
    "pkill -f run.zsh",
    "docker rm -f foo",
    "container delete foo",
  ]) {
    expect(runHook(cmd, sentinel)).toBe("deny");
  }
});

test("sentinel active → a benign command with a mutating verb in a SIBLING field is allowed", () => {
  // Regression: the greedy sed capture pulled later JSON fields into the match,
  // so a benign `echo hi` with an unrelated sibling field mentioning `docker rm`
  // was wrongly denied. jq extraction stops at the command boundary.
  writeFileSync(sentinel, "pid=1 started=0 runner=x");
  const payload = '{"tool_input":{"command":"echo hi"},"description":"docker rm foo"}';
  const res = spawnSync("bash", [HOOK], {
    input: payload,
    encoding: "utf8",
    env: { ...process.env, SMOKE_SENTINEL_FILE: sentinel },
  });
  expect(res.stdout.includes('"deny"') ? "deny" : "allow").toBe("allow");
  rmSync(sentinel, { force: true });
});

test("sentinel active → read-only verbs and override are allowed", () => {
  writeFileSync(sentinel, "pid=1 started=0 runner=x");
  for (const cmd of [
    "container ls --format json",
    "docker inspect foo",
    "lsof -iTCP:8084",
    "ps aux",
    "SMOKE_GATE_OVERRIDE=1 docker exec foo sh",
  ]) {
    expect(runHook(cmd, sentinel)).toBe("allow");
  }
  rmSync(sentinel, { force: true });
});

test("smoke-init wires the mutation gate into the consumer .claude/", () => {
  const proj = mkdtempSync(join(tmpdir(), "smoke-gate-init-"));
  mkdirSync(join(proj, ".git"), { recursive: true });
  const res = spawnSync("zsh", [INIT,
    "--install-path", "smoke",
    "--topic", "demo",
    "--non-interactive",
    "--sut-bin", "/tmp/fake-sut",
    "--sut-repo", "/tmp",
    "--build-cmd", ":",
  ], { cwd: proj, encoding: "utf8" });
  if (res.status !== 0) {
    console.log("STDOUT:", res.stdout, "\nSTDERR:", res.stderr);
  }
  expect(res.status).toBe(0);

  const hookPath = join(proj, ".claude", "hooks", "smoke-active-gate.sh");
  expect(existsSync(hookPath)).toBe(true);
  // Executable bit set.
  expect(statSync(hookPath).mode & 0o111).toBeGreaterThan(0);

  const settings = JSON.parse(readFileSync(join(proj, ".claude", "settings.json"), "utf8"));
  const cmds: string[] = (settings.hooks?.PreToolUse ?? [])
    .flatMap((e: any) => (e.hooks ?? []).map((h: any) => h.command ?? ""));
  expect(cmds.some((c) => c.includes("smoke-active-gate.sh"))).toBe(true);

  rmSync(proj, { recursive: true, force: true });
});

test("install_mutation_gate_hook returns 1 and preserves an invalid settings.json", () => {
  const proj = mkdtempSync(join(tmpdir(), "smoke-gate-bad-"));
  mkdirSync(join(proj, ".claude"), { recursive: true });
  const bad = "{ this is not json";
  writeFileSync(join(proj, ".claude", "settings.json"), bad);

  const payload = join(SKILL_ROOT, "payload");
  const libSync = join(SKILL_ROOT, "scripts", "lib-sync.zsh");
  const res = spawnSync("zsh", ["-c",
    `source '${libSync}'\ninstall_mutation_gate_hook '${payload}' '${proj}'`],
    { encoding: "utf8" });
  expect(res.status).toBe(1);
  expect(res.stderr).toContain("not valid JSON");
  // Hook still copied (fail-safe), original file untouched.
  expect(existsSync(join(proj, ".claude", "hooks", "smoke-active-gate.sh"))).toBe(true);
  expect(readFileSync(join(proj, ".claude", "settings.json"), "utf8")).toBe(bad);
  rmSync(proj, { recursive: true, force: true });
});

test("project_root_of walks to the git root, else falls back to the start dir", () => {
  const libSync = join(SKILL_ROOT, "scripts", "lib-sync.zsh");
  const withGit = mkdtempSync(join(tmpdir(), "smoke-root-"));
  mkdirSync(join(withGit, ".git"), { recursive: true });
  mkdirSync(join(withGit, "a", "b"), { recursive: true });
  const noGit = mkdtempSync(join(tmpdir(), "smoke-noroot-"));
  const deep = join(noGit, "x", "y");
  mkdirSync(deep, { recursive: true });

  const r1 = spawnSync("zsh", ["-c",
    `source '${libSync}'\nproject_root_of '${join(withGit, "a", "b")}'`], { encoding: "utf8" });
  expect(r1.stdout.trim()).toBe(withGit);
  const r2 = spawnSync("zsh", ["-c",
    `source '${libSync}'\nproject_root_of '${deep}'`], { encoding: "utf8" });
  expect(r2.stdout.trim()).toBe(deep);

  rmSync(withGit, { recursive: true, force: true });
  rmSync(noGit, { recursive: true, force: true });
});

test("hook wiring is idempotent and preserves existing hooks + other keys", () => {
  const proj = mkdtempSync(join(tmpdir(), "smoke-gate-idem-"));
  mkdirSync(join(proj, ".claude"), { recursive: true });
  writeFileSync(join(proj, ".claude", "settings.json"), JSON.stringify({
    permissions: { allow: ["Bash(ls:*)"] },
    hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "my-other-hook.sh" }] }] },
  }));

  // Call install_mutation_gate_hook directly, twice, via a sourced zsh snippet.
  const payload = join(SKILL_ROOT, "payload");
  const libSync = join(SKILL_ROOT, "scripts", "lib-sync.zsh");
  const snippet =
    `source '${libSync}'\n` +
    `install_mutation_gate_hook '${payload}' '${proj}'\n` +
    `install_mutation_gate_hook '${payload}' '${proj}'\n`;
  const res = spawnSync("zsh", ["-c", snippet], { encoding: "utf8" });
  if (res.status !== 0) console.log("STDOUT:", res.stdout, "\nSTDERR:", res.stderr);
  expect(res.status).toBe(0);

  const settings = JSON.parse(readFileSync(join(proj, ".claude", "settings.json"), "utf8"));
  const cmds: string[] = (settings.hooks?.PreToolUse ?? [])
    .flatMap((e: any) => (e.hooks ?? []).map((h: any) => h.command ?? ""));
  // Existing hook preserved, gate present, gate not duplicated across two runs.
  expect(cmds.some((c) => c.includes("my-other-hook.sh"))).toBe(true);
  expect(cmds.filter((c) => c.includes("smoke-active-gate.sh")).length).toBe(1);
  expect(settings.permissions.allow).toEqual(["Bash(ls:*)"]);

  rmSync(proj, { recursive: true, force: true });
});
