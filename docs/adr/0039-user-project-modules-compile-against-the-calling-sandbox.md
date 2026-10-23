---
status: proposed
---

# User project modules compile against the calling script's sandbox

Issue #150. A project's house rules and FH API workarounds had to be re-typed into every
run_lua script, because each call gets a fresh env and the sandbox has no `require`.

**Decision.** `require(name)` inside run_lua loads `<name>.lua` and compiles it with
`load(text, "@<name>.lua", "t", env)` against the **calling script's own env**. So a module
gets the same allowlist, write tracker, Visibility-filtered `fhBridge` and watchdog as the
script, and can do nothing a script can't (ADR 0001's trust model unchanged).

- **Two folders, project first.** `<CI_PROJECT_DATA_FOLDER>\Plugin Data\AI Connector\modules\`,
  then a machine-wide `AI Connector\modules\` in FH's machine Plugin Data folder, so one set
  of helpers can serve every project and a project can override one by name. The machine
  folder comes from `fhGetPluginDataFileName("LOCAL_MACHINE")`'s parent, not a hard-coded
  path: FH's help gives `<Plugins>\Data` for that scope, but FH 8 returns
  `C:\ProgramData\Calico Pie\Family Historian 8\Plugin Data`, where the Bridge's own settings
  already live. The subfolder name is fixed, not the plugin's own, so a renamed plugin file
  finds the same modules. Not `CI_APP_DATA_FOLDER` itself, which FH asks plugins not to use.
- **Per call, not per Session.** The env and tracker are rebuilt every call; a module bound
  to an earlier env would write past the current call's tracker and rollback. Text is
  re-read each call, so an edited module needs no restart. Within one call a module loads
  once.
- **Read Bridge-side, not from the sandbox.** `fhLoadTextFile` stays excluded from run_lua;
  the plugin reads the file. Names are `^[%w_]+$`, so nothing outside the folders is
  reachable.
- **Pre-scans apply to module text**, minus the write-name scan: a module of write helpers
  is legitimate in Read-only for its read helpers, its write calls find no write function
  there, and in Read-write the runtime write-then-log backstop (ADR 0012) covers module
  code exactly as it covers the script's.
- **The user installs modules, not the Bridge.** No tool writes to either folder; copying a
  file in by hand is the review checkpoint (cf. ADRs 0004, 0008).
- **Discoverable without spending run_lua's description budget** (ADR 0011: it is at 1,942 of
  1,950 bytes). `fhBridge.listModules()` and `describe_project`'s `userModules` report what is
  installed and where; the gedcom-knowledge corpus has `run-lua-guidance-user-project-modules`
  and an `fhBridge.listModules` reference entry.

**Rejected.** A plain `require` in the entry file (unsandboxed, real `fh*`, bypasses the
tracker and Read-only). A server-side prelude prepended to every script (shifts line
numbers, compiles every helper every call, and the write-name pre-scan would reject every
Read-only script once one write helper is in it).
