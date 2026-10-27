---
status: accepted
---

# User project modules compile against the calling script's sandbox

Issue #150. A project's house rules and FH API workarounds had to be re-typed into every
run_lua script, because each call gets a fresh env and the sandbox has no `require`.

**Decision.** `require(name)` inside run_lua loads `<name>.lua` and compiles it with
`load(text, "@<name>.lua", "t", env)` against the **calling script's own env**. So a module
gets the same allowlist, write tracker, Visibility-filtered `fhBridge` and watchdog as the
script, and can do nothing a script can't (ADR 0001's trust model unchanged).

- **Two folders, project first.** `<CI_PROJECT_DATA_FOLDER>\Plugin Data\AI Connector\modules\`,
  then the user's own `AI Connector\modules\` in FH's per-user Plugin Data folder, so one set
  of helpers can serve all of a user's projects and a project can override one by name. The
  user folder comes from `fhGetPluginDataFileName("CURRENT_USER")`'s parent, not a
  hard-coded path: FH's help gives `Calico Pie\Family Historian\Plugin Data` under the
  user's application data, but FH 8 returns
  `%APPDATA%\Calico Pie\Family Historian 8\Plugin Data`. The subfolder name is fixed, not the
  plugin's own, so a renamed plugin file finds the same modules. Not `CI_APP_DATA_FOLDER`,
  which FH asks plugins not to use.
- **Per user, not per machine.** The first version searched FH's machine-wide Plugin Data
  folder (`LOCAL_MACHINE`) instead. FH 8's installer gives Everyone Modify on that folder, so
  on a shared PC another account could put a module there that would run in your Session
  without your having read it. The per-user folder is writable only by that user (and
  SYSTEM and Administrators), so the hand-install checkpoint holds for both folders. Sharing
  one module between Windows accounts on the same PC means copying it into each.
- **Per call, not per Session.** The env and tracker are rebuilt every call; a module bound
  to an earlier env would write past the current call's tracker and rollback. Text is
  re-read each call, so an edited module needs no restart. Within one call a module loads
  once. A module that fails to load isn't remembered, so a script that catches the error
  with `pcall` can require it again, or carry on without it.
- **No source cache across calls.** Reading one small text file per require costs about what
  checking its modified time would, and a cache adds a way to run a stale copy.
- **Read Bridge-side, not from the sandbox.** `fhLoadTextFile` stays excluded from run_lua;
  the plugin reads the file. Names are `^[A-Za-z0-9_]+$` (spelt out, since `%w` follows the
  C locale), so nothing outside the folders is reachable by name. Names are matched ignoring
  case, for loading once per call and for shadowing, because Windows finds the same file
  either way. Junctions and symbolic links inside a folder aren't checked: the folders are
  the user's own, and a link points only where the user put it.
- **An unreadable module is an error, not a miss.** `fhLoadTextFile` returns nil for a
  missing file and an unreadable one alike, so on nil the reader checks whether the file
  exists; if it does, `require` fails naming it, rather than falling through to a
  same-named module in the user folder.
- **Pre-scans apply to module text**, minus the write-name scan: a module of write helpers
  is legitimate in Read-only for its read helpers, its write calls find no write function
  there, and in Read-write the runtime write-then-log backstop (ADR 0012) covers module
  code exactly as it covers the script's. Module text is always scanned against the
  Session's real Visibility settings (ADR 0038), including when describe_project's listing
  loads it: describe_project's own fixed script runs unfiltered, but the modules it loads are
  user-supplied.
- **The user installs modules, not the Bridge.** No tool writes to either folder; copying a
  file in by hand is the review checkpoint (cf. ADRs 0004, 0008).
- **Discoverable without spending run_lua's description budget** (ADR 0011: it is at 1,942 of
  1,950 bytes). `describe_project`'s `userModules` reports what is installed and where.
  describe_project's own script runs in the sandbox, so the listing reaches it as
  `fhBridge.listModules()`, which scripts can call too. To say whether each module loaded and
  what it exports (names, plus an optional `_DOC` table of one-line descriptions), the
  listing loads every module that isn't shadowed through the script's own `require`, so a
  later require in that call reuses it. Each load gets its own instruction budget
  (`watchdog.isolated`): the main watchdog, once past its limit, fires again every thousand
  instructions, so one looping module would otherwise sink describe_project. Those loads
  don't count against the script's own 50M; instead each gets at most 5M and the whole
  listing at most 10M, so however many modules loop, a listing adds at most a fifth to the
  script's budget. Modules load in name order, and any the total doesn't reach are listed as
  not loaded, without running.
- **The listing loads modules only in Read-only.** Loading runs a module's top-level code,
  and in a Read-write Session that code could write; the writes would be tracked and logged,
  but nobody expects a listing to write. So in Read-write, `listModules` only lists, without
  `loaded`, `exports` or `doc`. describe_project always runs Read-only, so it always gets the
  full listing.
- The gedcom-knowledge corpus has `run-lua-guidance-user-project-modules` and an
  `fhBridge.listModules` reference entry.

**Rejected.** A plain `require` in the entry file (unsandboxed, real `fh*`, bypasses the
tracker and Read-only). A server-side prelude prepended to every script (shifts line
numbers, compiles every helper every call, and the write-name pre-scan would reject every
Read-only script once one write helper is in it).
