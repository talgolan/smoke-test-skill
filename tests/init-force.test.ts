import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");

test("smoke-init --force creates sibling backup dir with prior contents", () => {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-"));
  try {
    mkdirSync(join(work, "smoke", "lib"), { recursive: true });
    writeFileSync(join(work, "smoke", "lib", "old.zsh"), "# old lib\n");
    writeFileSync(join(work, "smoke", "AUTHORING_GUIDE.md"), "# old guide\n");
    writeFileSync(join(work, "smoke", ".smokerc"), "# old .smokerc\n");

    const res = spawnSync("zsh", [INIT,
      "--install-path", "smoke",
      "--topic", "demo",
      "--force",
      "--non-interactive",
      "--sut-bin", "/tmp/x", "--sut-repo", "/tmp", "--build-cmd", ":",
    ], { cwd: work, encoding: "utf8" });

    if (res.status !== 0) {
      console.log("STDOUT:", res.stdout);
      console.log("STDERR:", res.stderr);
    }
    expect(res.status).toBe(0);

    expect(existsSync(join(work, "smoke", "lib", "env.zsh"))).toBe(true);

    const siblings = readdirSync(work);
    const backups = siblings.filter(s => s.startsWith("smoke.backup-"));
    expect(backups.length).toBe(1);

    const backupDir = join(work, backups[0]);
    expect(existsSync(join(backupDir, "lib"))).toBe(true);
    expect(existsSync(join(backupDir, "AUTHORING_GUIDE.md"))).toBe(true);
    expect(existsSync(join(backupDir, ".smokerc"))).toBe(true);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
