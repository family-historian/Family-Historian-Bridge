# Automatic per-Session activity log, steered from run_lua's description

Working issue #23 (adding media to FH projects) surfaced a gap the other way round from
ADR 0006's: nothing recorded *what Claude did* during a Read-write Session, and nothing
reminded the user which sources still needed a physical/digital item (a photo, a
certificate) attached by hand afterwards. The 2026-08-01 grilling session on #23 decided
Claude should keep this log automatically — the user should never have to ask for a "log"
or a "note" — and that this project should stay strictly instructional for the media
transfer itself: it never touches the media file's bytes or the filesystem.

Decisions:

1. **Steer this from `run_lua`'s tool description, not a Skill**, for the same reason as
   ADR 0006's citeSource steering: a Skill (`SKILL.md`) is Claude-Code-only and wouldn't
   travel with the MCP server to another host, while `run_lua`'s description is part of
   the MCP protocol response itself. `run_lua`'s description now tells Claude to call
   `fhBridge.logActivity(ptrRecord, action)` after every record-touching action in a
   Read-write Session — not just once at the end — and never in a Read-only Session or
   after a script that made no writes.
2. **One Research Note (`_RNOT`) per Session, created on first use, appended to on every
   later call.** `sessionLogHelper.lua` (issue #36) exploits the Bridge plugin being one
   continuously-running Lua process for a Session's lifetime: a module-level Lua variable
   (the note's own item pointer, and a RichText buffer mirroring what's been saved to it
   so far) persists naturally across every `run_lua` call in that Session via `require()`'s
   module caching, and is gone on the next Session, since a fresh plugin load reruns the
   module's top level from scratch. This means `logActivity` never reads the note's
   existing content back from FH and merges into it, and Claude never tracks or passes
   back a note pointer of its own — it just calls `logActivity` again. A Read-only
   Session, or a Read-write Session that never calls `logActivity` (no records touched),
   creates no note at all: the note only comes into existence on that first call.
3. **Record references are live FTF record links, not plain text** — `RichText`'s
   `AddRecordLink`, labelled via `fhGetQualifiedRecordId` — so opening the note in FH lets
   the user click straight through to each record touched, the same reasoning as
   `citeSource`'s own citation links.
4. **Outstanding media stays instructional-only.** `logActivity`'s optional third
   argument (`{name, location}`, issue #39) appends an indented, plain-FTF
   `[ ] #ToDo Media to be added <name>` sub-line under the entry it concerns — a checklist
   line the user ticks off by hand in FH, not an interactive checkbox and not a real
   attachment. Nothing in this project ever reads or writes the media file's bytes, or
   touches the filesystem, for this: the user still has to drag the actual file into FH
   themselves once the Session ends. This mirrors the project's existing filesystem
   exclusion policy (`bridge/sandbox.lua`'s permanently-excluded `fhGetValueAsBlob`/
   `fhSetValueAsBlob`) rather than carving out a one-off exception for media.
5. **Wired into `bridge/sandbox.lua`'s Read-write allowlist the same way `sourceHelper.lua`
   is** — `env.fhBridge.logActivity`, gated read-write-only and wrapped by the same write
   tracker as `citeSource`/`createSourceFromTemplate`, since it also calls the real `fh*`
   globals directly rather than going through the sandboxed proxy.
