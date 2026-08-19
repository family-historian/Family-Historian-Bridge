# Debug log: full-file rewrite via fhSaveTextFile, outside the sandbox

Issue #122 added an off-by-default debug logging mode: every `run_lua` call's script and
result written to a plain-text file under the project's public folder, so a user can
review what Claude actually ran without digging through Claude's UI. Distinct from ADR
0010's automatic Research Note: that's an in-FH-data activity summary Claude itself writes
via `fhBridge.logActivity`, steered by `run_lua`'s tool description; this is a Bridge-side,
non-Claude-visible raw transcript, always written by `bridgeSession.lua` regardless of
what Claude does.

Decisions:

1. **`fhFileUtils`/`fhSaveTextFile` over plain `io`/`lfs`.** FH's own docs warn plain
   `io`/`lfs` don't handle extended-UTF-8 filenames well on Windows, and a project's public
   folder can be named with any character the user's OS allows. `fhFileUtils.folderExists`/
   `createFolder` manage the `debug` subfolder; the bare `fhSaveTextFile` global writes the
   file.
2. **Full-file rewrite per entry, not append.** `fhSaveTextFile` has no append mode and
   there's no `fh*` append primitive. A Session's `run_lua` call count is small enough that
   rewriting the accumulated in-memory text (`debugLog.lua`'s `Session.content`) on every
   call is cheap; simpler than tracking file offsets or opening/closing a handle per call.
3. **A write failure disables the rest of that Session's logging, not just the failed
   call.** If the initial folder-create or header write fails, `Session.enabled` is never
   set true — logging silently never starts for that Session. If a later `logRunLua` write
   fails, the in-memory `content` is left un-advanced by that entry but the session stays
   enabled and retries on the next call, matching the issue's "any write failure is silent
   and non-blocking; `run_lua` must always execute and return normally" requirement.
4. **Entirely outside `runScript.lua`'s sandbox**, called only from `bridgeSession.lua`.
   `sandbox.lua`'s `EXCLUDED_FH_GLOBAL_REASONS` deliberately keeps filesystem access out of
   Claude-authored `run_lua` scripts; this module must never be reachable from inside that
   sandbox, and only a plain `LUA <n>` request (`run_lua`'s own call, not
   `describe_project`/`install_fh_plugin`'s fixed `LUA_RO <n>` scripts) is logged.
