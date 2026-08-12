#!/usr/bin/env node
// Runs every bridge/tests/*.test.lua through a Lua interpreter and fails on the first
// non-zero exit. Written in Node rather than as a shell loop in package.json so that
// `npm test` behaves the same from bash on the Mac and from PowerShell/cmd on Windows,
// where the release scripts also run it.
//
// Interpreter lookup mirrors the two release scripts: LUA_BIN wins (release-mac.sh's
// convention), then `lua` on PATH, then stage.ps1's fixed Windows location.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const testsDir = join(repoRoot, "bridge", "tests");

const runnable = (bin) => {
  const probe = spawnSync(bin, ["-v"], { stdio: "ignore" });
  return !probe.error && probe.status === 0;
};

function resolveLua() {
  // An explicit LUA_BIN is still probed: a stale path should say "not a working
  // interpreter", not fail all 12 files as if the tests themselves broke.
  if (process.env.LUA_BIN) {
    return runnable(process.env.LUA_BIN) ? process.env.LUA_BIN : null;
  }
  if (runnable("lua")) return "lua";
  const windowsFallback = "C:\\Utils\\lua\\lua.exe";
  if (existsSync(windowsFallback) && runnable(windowsFallback)) return windowsFallback;
  return null;
}

const lua = resolveLua();
if (!lua) {
  console.error(
    process.env.LUA_BIN
      ? `LUA_BIN is set to '${process.env.LUA_BIN}', which is not a working Lua interpreter.`
      : "No Lua interpreter found. Set LUA_BIN to its full path, or install one " +
          "(macOS: 'brew install lua'; Windows: see installer/stage.ps1).",
  );
  process.exit(1);
}

const files = readdirSync(testsDir)
  .filter((name) => name.endsWith(".test.lua"))
  .sort();

if (files.length === 0) {
  console.error(`No *.test.lua files found in ${testsDir}`);
  process.exit(1);
}

// Bounds any single test file (issue: a Lua interpreter with a broken debug.sethook
// count-hook lets runScript.test.lua's runaway-loop check spin forever instead of
// aborting in ~10s as it expects -- reproduced 2026-08-12 against a Windows Lua 5.1.5
// build, which sat at 100% CPU for 28 minutes before being killed by hand. Without this
// timeout that hang is silent: spawnSync has no default bound and just blocks the whole
// release script. See docs/release.md's "Risks" section for the full story and why Lua
// 5.3.x (matching FH's own embedded runtime) is what actually fixed it.
const TEST_TIMEOUT_MS = 30_000;

let ran = 0;
let failure = null;
for (const file of files) {
  const result = spawnSync(lua, [join(testsDir, file)], {
    cwd: repoRoot,
    stdio: "inherit",
    timeout: TEST_TIMEOUT_MS,
  });
  ran += 1;
  const timedOut = result.signal !== null;
  const ok = !result.error && !timedOut && result.status === 0;
  if (timedOut) {
    console.error(
      `\n${file} did not finish within ${TEST_TIMEOUT_MS}ms and was killed. This usually ` +
        `means the Lua interpreter's debug.sethook count-hook isn't firing correctly ` +
        `(seen with Lua 5.1.5 on Windows) -- check 'lua -v' reports 5.3.x, matching FH's ` +
        `own embedded runtime, not an older/different build.`,
    );
  }
  console.log(`${ok ? "ok" : "FAIL"} ${file}`);
  if (!ok) {
    failure = file;
    break;
  }
}

console.log(
  failure
    ? `\nbridge: FAILED at ${failure} (${ran} of ${files.length} files run)`
    : `\nbridge: ${files.length} files passed`,
);
process.exit(failure ? 1 : 0);
