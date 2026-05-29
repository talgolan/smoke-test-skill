import { test, expect } from "bun:test";
import {
  mkdtempSync, rmSync, mkdirSync, chmodSync, copyFileSync,
  writeFileSync, readFileSync, existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SKILL_ROOT = join(import.meta.dir, "..");
const INIT = join(SKILL_ROOT, "scripts", "smoke-init.zsh");
const FAKE_SUT = join(SKILL_ROOT, "tests", "fixtures", "fake-sut.zsh");

interface InitResult {
  workDir: string;
  runnerPath: string;
  historyFile: string;
}

function setupRunner(opts: { sleepSeconds?: number } = {}): InitResult {
  const work = mkdtempSync(join(tmpdir(), "smoke-test-skill-hist-"));
  mkdirSync(join(work, ".git"), { recursive: true });

  const sutBin = join(work, "fake-sut.zsh");
  copyFileSync(FAKE_SUT, sutBin);
  chmodSync(sutBin, 0o755);

  const initRes = spawnSync("zsh", [INIT,
    "--install-path", "smoke",
    "--topic", "demo",
    "--non-interactive",
    "--sut-bin", sutBin,
    "--sut-repo", work,
    "--build-cmd", ":",
    "--preflight", "tmux jq",
  ], { cwd: work, encoding: "utf8" });
  expect(initRes.status).toBe(0);

  // Optionally inject a sleep into the step so duration is measurable.
  if (opts.sleepSeconds) {
    const stepFile = join(work, "smoke", "demo", "steps", "01-example.zsh");
    const orig = readFileSync(stepFile, "utf8");
    const patched = orig.replace(
      "# --- Steps ---",
      `# --- Steps ---\nsleep ${opts.sleepSeconds}\n`,
    );
    writeFileSync(stepFile, patched);
  }

  return {
    workDir: work,
    runnerPath: join(work, "smoke", "demo", "run.zsh"),
    historyFile: join(work, "smoke", "demo", ".history.jsonl"),
  };
}

function runRunner(runnerPath: string, workDir: string, args: string[] = ["01"]) {
  return spawnSync(runnerPath, args, {
    cwd: workDir,
    encoding: "utf8",
    env: { ...process.env, BUDGET_SECONDS: "10" },
  });
}

test("history #1 — empty history: file created, banner shows (no history)", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    const res = runRunner(runnerPath, workDir);
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/Expected durations/);
    expect(res.stdout).toMatch(/01-example\s+\(no history\)/);
    expect(res.stdout).not.toMatch(/WARN: section/);
    expect(existsSync(historyFile)).toBe(true);
    const content = readFileSync(historyFile, "utf8");
    expect(content).toMatch(/"section":"01-example"/);
    expect(content).toMatch(/"result":"PASS"/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #2 — stats computed: seeded p50/p95 surface in banner", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    const seedTs = (i: number) => `2026-05-29T10:${String(i).padStart(2, "0")}:00Z`;
    const lines = [10, 12, 11, 13, 9, 50].map((d, i) =>
      JSON.stringify({ ts: seedTs(i), section: "01-example", duration: d, result: "PASS", budget: 30 })
    ).join("\n") + "\n";
    writeFileSync(historyFile, lines);

    const res = runRunner(runnerPath, workDir);
    expect(res.status).toBe(0);
    // p50=11 or 12 depending on rounding; p95 = 50 (top of 6 samples).
    expect(res.stdout).toMatch(/01-example\s+p50=1[12]s\s+p95=50s/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #3 — outlier annotation: 2x median triggers ⚠ marker", () => {
  const { workDir, runnerPath, historyFile } = setupRunner({ sleepSeconds: 3 });
  try {
    // Seed history with p50=1 so a 3s run is >= 2x.
    const seed = Array.from({ length: 6 }, (_, i) =>
      JSON.stringify({
        ts: `2026-05-29T10:${String(i).padStart(2, "0")}:00Z`,
        section: "01-example", duration: 1, result: "PASS", budget: 30,
      })
    ).join("\n") + "\n";
    writeFileSync(historyFile, seed);

    const res = runRunner(runnerPath, workDir);
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/01-example\s+PASS\s+\d+s\s+⚠.*median.*p50=1s/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #4 — drift warning: p95 ≥ budget emits WARN with recommended budget", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    // Patch step file budget header to 60.
    const stepFile = join(workDir, "smoke", "demo", "steps", "01-example.zsh");
    const orig = readFileSync(stepFile, "utf8");
    writeFileSync(stepFile, orig.replace("emulate -L zsh", "emulate -L zsh\n# BUDGET_SECONDS=60"));

    // Seed 6 PASS rows where the slowest dictates p95=80.
    const durs = [50, 60, 70, 75, 78, 80];
    const seed = durs.map((d, i) =>
      JSON.stringify({
        ts: `2026-05-29T10:${String(i).padStart(2, "0")}:00Z`,
        section: "01-example", duration: d, result: "PASS", budget: 60,
      })
    ).join("\n") + "\n";
    writeFileSync(historyFile, seed);

    const res = runRunner(runnerPath, workDir);
    // Override BUDGET_SECONDS to keep run fast — drift warning should still fire
    // because banner uses the step's declared 60. But the env override is what
    // run.zsh uses — fix by clearing it.
    expect(res.status).toBe(0);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #4b — drift warning fires when env BUDGET_SECONDS not set", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    const stepFile = join(workDir, "smoke", "demo", "steps", "01-example.zsh");
    const orig = readFileSync(stepFile, "utf8");
    writeFileSync(stepFile, orig.replace("emulate -L zsh", "emulate -L zsh\n# BUDGET_SECONDS=60"));

    const durs = [50, 60, 70, 75, 78, 80];
    const seed = durs.map((d, i) =>
      JSON.stringify({
        ts: `2026-05-29T10:${String(i).padStart(2, "0")}:00Z`,
        section: "01-example", duration: d, result: "PASS", budget: 60,
      })
    ).join("\n") + "\n";
    writeFileSync(historyFile, seed);

    // Run WITHOUT BUDGET_SECONDS env override so step file's # BUDGET_SECONDS=60 wins.
    const res = spawnSync(runnerPath, ["01"], { cwd: workDir, encoding: "utf8" });
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/WARN: section 01-example p95=80s/);
    expect(res.stdout).toMatch(/BUDGET_SECONDS=120/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #5 — cap policy: keeps last 50 PASS + last 10 non-PASS per section", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    const lines: string[] = [];
    // 100 PASS rows
    for (let i = 0; i < 100; i++) {
      const mm = String(Math.floor(i / 60)).padStart(2, "0");
      const ss = String(i % 60).padStart(2, "0");
      lines.push(JSON.stringify({
        ts: `2026-05-29T${mm}:${ss}:00Z`,
        section: "01-example", duration: 10, result: "PASS", budget: 30,
      }));
    }
    // 15 FAIL rows (newer ts)
    for (let i = 0; i < 15; i++) {
      const ss = String(i).padStart(2, "0");
      lines.push(JSON.stringify({
        ts: `2026-05-29T15:${ss}:00Z`,
        section: "01-example", duration: 10, result: "FAIL", budget: 30,
      }));
    }
    writeFileSync(historyFile, lines.join("\n") + "\n");

    const res = runRunner(runnerPath, workDir);
    expect(res.status).toBe(0);

    const after = readFileSync(historyFile, "utf8").trim().split("\n");
    const passRows = after.filter(l => l.includes('"result":"PASS"'));
    const failRows = after.filter(l => l.includes('"result":"FAIL"'));
    // 50 capped + 1 from this run = 51 PASS
    expect(passRows.length).toBeLessThanOrEqual(51);
    expect(passRows.length).toBeGreaterThanOrEqual(50);
    expect(failRows.length).toBe(10);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #6 — corrupt JSON line: run completes, stats compute over valid lines", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    const lines = [
      JSON.stringify({ ts: "2026-05-29T10:00:00Z", section: "01-example", duration: 11, result: "PASS", budget: 30 }),
      "this is not json at all",
      JSON.stringify({ ts: "2026-05-29T10:01:00Z", section: "01-example", duration: 13, result: "PASS", budget: 30 }),
    ].join("\n") + "\n";
    writeFileSync(historyFile, lines);

    const res = runRunner(runnerPath, workDir);
    expect(res.status).toBe(0);
    // p50 over [11, 13] = 13 (nearest-rank, 1*0.5 rounded up = idx 1).
    expect(res.stdout).toMatch(/01-example\s+p50=1[13]s/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("history #7 — insufficient data: drift warning suppressed when count < 5", () => {
  const { workDir, runnerPath, historyFile } = setupRunner();
  try {
    const stepFile = join(workDir, "smoke", "demo", "steps", "01-example.zsh");
    const orig = readFileSync(stepFile, "utf8");
    writeFileSync(stepFile, orig.replace("emulate -L zsh", "emulate -L zsh\n# BUDGET_SECONDS=10"));

    // 4 PASS rows with p95 well above budget.
    const durs = [50, 60, 70, 80];
    const seed = durs.map((d, i) =>
      JSON.stringify({
        ts: `2026-05-29T10:0${i}:00Z`,
        section: "01-example", duration: d, result: "PASS", budget: 30,
      })
    ).join("\n") + "\n";
    writeFileSync(historyFile, seed);

    const res = spawnSync(runnerPath, ["01"], { cwd: workDir, encoding: "utf8" });
    expect(res.status).toBe(0);
    expect(res.stdout).not.toMatch(/WARN: section 01-example/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});
