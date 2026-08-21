# Domain — Rich text / activity logging

- **FTF** (Family Historian Text Format): FH's internal rich-text markup for any
  multi-line field (Notes, Source TEXT, citation DATA/TEXT) — inline style commands,
  tables, web/record/citation links, `[[private]]` spans. Distinct from eFTF (report-only
  superset) and tFTF (the SetText API's text-only variant, basis for get/setTftfText).
  Avoid "Rich text" alone when FTF's specific grammar is meant.
- **getTftfText / setTftfText** (`bridge/richTextHelper.lua`): mid-document RichText edit
  pair (not just append — logActivity already covers append via live AddText/
  AddRecordLink). `getTftfText` rewrites eFTF's index-based `<rec=N,...>` refs into
  self-contained `<rec=QualifiedId,...>` (tFTF) — safe for ordinary string splicing.
  `setTftfText` commits back via one full-document `SetText(text,true,true)`. Neither
  touches a field with embedded source citations — tFTF can't represent a citation, and
  SetText silently discards one rather than erroring; `getTftfText` reports
  `editable=false` with a reason, `setTftfText` errors outright. Editing a
  citation-bearing field's interior is out of scope (ADR 0025). Avoid a hand-rolled
  GetText/tblRecLinks/SetText round trip for record-link edits — proven broken beyond
  exact passthrough.
- **logActivity** (`bridge/sessionLogHelper.lua`): logs a Read-write Session's
  record-creating activity into one `_RNOT` Research Note per Session (created on first
  call, appended after). `ptrRecord` accepts a Fact/sub-item pointer too — auto-climbs to
  the owning record via `MoveToRecordItem` rather than erroring (ADR 0031; known gap: a
  Shared Fact witness item climbs to the fact's principal, not the witness). Note uses a
  labelled-field header (`Title:`/`Type:`/`Status:`/`Date:`, FH's labelled-paragraph
  convention) — `Title:` drives the record's actual display name/Records-Window name, so
  it must stay the first labelled paragraph; only `Title:` keeps bold+heading styling.
  `Type="mcp-log"`/`Status="closed"` are fixed constants (enables Smart-Folder cleanup
  queries). Enforced by the write-then-log invariant — see `mem:conventions`. Distinct
  from a Whole-record citation — this is a Claude-authored log, not a source attachment.
  `M.getNotePtr()` exposes the module-level note pointer (nil until the first
  `logActivity` call, and not reset between Start/Stop — scoped to the whole plugin load,
  not one Session) — `bridgeSession.lua` reads it on close to decide whether to show the
  note via `fhOutputNote` (issue #115, FH-8-beta-only — `fhGetAppVersion()` returns its 3
  version numbers as separate integers, not a dotted string, so its first return value is
  compared to 8 directly, no `versionCompare` parse involved; skipped when
  `pendingRethrow` is set since FH's own rollback is about to undo the note anyway).
- **run_lua guidance (corpus entries)**: see `mem:server`'s RUN_LUA_DESCRIPTION-truncation
  note and `mem:corpora` — the "run_lua guidance"-titled GEDCOM-corpus entries carry the
  overflow that a deferred/lazy MCP tool-schema loader would silently truncate past ~2KB
  if left in the tool description itself.
