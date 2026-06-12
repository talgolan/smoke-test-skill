import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const SKILL_ROOT = join(import.meta.dir, "..");

const FILES = [
  "payload/lib/env.zsh",
  "payload/lib/log.zsh",
  "payload/lib/control.zsh",
  "payload/lib/pause.zsh",
  "payload/lib/term-a.zsh",
  "payload/template/run.zsh",
  "payload/template/lib/topic-helpers.zsh",
  "payload/template/steps/01-example.zsh",
  "scripts/smoke-init.zsh",
  "scripts/smoke-add.zsh",
  "scripts/smoke-sync.zsh",
  "scripts/lib-sync.zsh",
];

for (const f of FILES) {
  test(`shellcheck: ${f}`, () => {
    // shellcheck for zsh files: pass --shell=bash (closest dialect supported).
    // Disabled checks:
    //   SC2154 (var ref'd but not assigned) — common across sourced files
    //   SC1090/SC1091 (can't follow source) — sourced files at runtime, not parseable
    //   SC2034 (unused) — typeset -ga arrays look "unused" until run.zsh iterates
    //   SC2296 (expansion can't start with `(`) — zsh ${(@s:.:)x} split flag
    const res = spawnSync(
      "shellcheck",
      ["--shell=bash", "-e", "SC2154,SC1090,SC1091,SC2034,SC2296", join(SKILL_ROOT, f)],
      { encoding: "utf8" }
    );
    if (res.status !== 0) {
      console.log(`shellcheck output for ${f}:\n${res.stdout}`);
    }
    expect(res.status).toBe(0);
  });
}
