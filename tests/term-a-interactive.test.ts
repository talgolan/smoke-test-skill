import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, chmodSync, copyFileSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");
const FAKE_SUT = join(SKILL_ROOT, "tests", "fixtures", "fake-sut.zsh");

// Drive the fake SUT's interactive `wizard` through term_a_start +
// term_a_answer, proving the interactive-SUT primitives answer prompts and
// that keying completion on a LAST-written sentinel works.
test("term_a_answer drives an interactive SUT wizard to completion", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, ".git"), { recursive: true });
    const sutBin = join(work, "fake-sut.zsh");
    copyFileSync(FAKE_SUT, sutBin);
    chmodSync(sutBin, 0o755);

    const initRes = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "wiz",
      "--non-interactive",
      "--sut-bin", sutBin,
      "--sut-repo", work,
      "--build-cmd", ":",
      "--preflight", "tmux jq",
    ], { cwd: work, encoding: "utf8" });
    expect(initRes.status).toBe(0);

    const outfile = join(work, "wizard-out.json");
    writeFileSync(
      join(work, "smoke", "wiz", "steps", "01-example.zsh"),
      [
        "#!/usr/bin/env zsh",
        "set -u",
        "emulate -L zsh",
        'sect "wizard drive"',
        `out_json='${outfile}'`,
        // Spawn the interactive wizard in a pty.
        'term_a_start "$SECTION_SLUG" "$SUT_BIN" wizard "$out_json"',
        // Answer its two prompts: accept default backend, then give harnesses.
        'term_a_answer "$SECTION_SLUG" "Backend .docker/container." "" 10',
        'term_a_answer "$SECTION_SLUG" "Enter harness ids" "claude sf" 10',
        // Wait for the LAST-written sentinel, not the first byte.
        "ready=false",
        "for _ in {1..20}; do",
        '  if [[ -f "$out_json" ]] && jq -e \'.completedInit == true\' "$out_json" >/dev/null 2>&1; then ready=true; break; fi',
        "  sleep 1",
        "done",
        'verify "wizard completed (sentinel written)" "$ready"',
        'verify "backend answer captured" "jq -e \'.backend == \\"docker\\"\' \\"$out_json\\""',
        'verify "harness answer captured" "jq -e \'.harnesses == \\"claude sf\\"\' \\"$out_json\\""',
        'term_a_close "$SECTION_SLUG"',
        "(( FAIL_COUNT > 0 )) && exit 1 || exit 0",
      ].join("\n"),
    );

    const runRes = spawnSync(
      join(work, "smoke", "wiz", "run.zsh"),
      ["01"],
      { cwd: work, encoding: "utf8", env: { ...process.env, BUDGET_SECONDS: "30" } },
    );
    if (runRes.status !== 0) {
      console.log("STDOUT:", runRes.stdout);
      console.log("STDERR:", runRes.stderr);
    }
    expect(existsSync(outfile)).toBe(true);
    expect(JSON.parse(readFileSync(outfile, "utf8")).harnesses).toBe("claude sf");
    expect(runRes.stdout + runRes.stderr).toContain("PASS  wizard completed");
    expect(runRes.status).toBe(0);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
