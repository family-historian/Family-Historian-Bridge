#!/usr/bin/env node
// Runs luacheck over bridge/ (config: .luacheckrc at repo root, which declares the fh*/
// fhu.* globals the FH host injects at runtime -- see that file's header for why).
//
// Interpreter/tool lookup mirrors run-bridge-tests.mjs: LUACHECK_BIN wins, then
// `luacheck` on PATH. No Windows fallback path is listed (unlike LUA_BIN) because
// luacheck isn't part of the release toolchain there yet -- add one if that changes.
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const runnable = (bin) => {
  const probe = spawnSync(bin, ["--version"], { stdio: "ignore" });
  return !probe.error && probe.status === 0;
};

function resolveLuacheck() {
  if (process.env.LUACHECK_BIN) {
    return runnable(process.env.LUACHECK_BIN) ? process.env.LUACHECK_BIN : null;
  }
  if (runnable("luacheck")) return "luacheck";
  return null;
}

const luacheck = resolveLuacheck();
if (!luacheck) {
  console.error(
    process.env.LUACHECK_BIN
      ? `LUACHECK_BIN is set to '${process.env.LUACHECK_BIN}', which is not a working luacheck.`
      : "No luacheck found. Set LUACHECK_BIN to its full path, or install one " +
          "(macOS: 'brew install luarocks' then 'luarocks install luacheck').",
  );
  process.exit(1);
}

const result = spawnSync(luacheck, ["bridge"], {
  cwd: repoRoot,
  stdio: "inherit",
});

process.exit(result.error ? 1 : result.status);
