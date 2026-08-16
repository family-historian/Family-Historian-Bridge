# FH MCP Bridge — Project Status Summary

**Date:** 2026-08-16 · **Version:** 0.14.0 · **Age:** ~3 weeks (started 2026-07-28)

## What it is

An MCP server + companion plugin that lets Claude read and edit a user's live
Family Historian genealogy project directly — no GEDCOM export/import round-trip.
Claude talks to the plugin over a local socket while FH is open.

## Status: active, healthy

- 215 commits, 5 minor releases (0.10 → 0.14) in 3 weeks — high velocity.
- 309 automated server tests + full Lua bridge test/lint suite, all passing,
  enforced automatically on every push (nothing ships untested).
- 28 architecture decision records — design choices are documented, not tribal
  knowledge.
- 50 issues closed, 4 open (below).

## Recent delivery (0.14.0)

- Plugin now reports its own live state (version, access mode) back through
  `describe_project`.
- Solved a longstanding rich-text editing limitation (mid-document edits that
  add new record links).
- Reduced duplicated validation/error-handling code across the write path.

## Open items (4)

| # | Item | Type |
|---|------|------|
| 56/60 | Windows installer breaks against the new unified Claude Desktop app (config file gets wiped); packaging fix in progress | In-progress work |
| 27 | Feature request to Calico Pie (FH vendor): refresh button in Plugins dialog | Blocked on vendor, no ETA |
| 66 | Feature request to Calico Pie: a Lua API to list record links | Blocked on vendor, no ETA |

**Watch item:** the Windows installer issue (#56/#60) is the only open risk to
new-user onboarding — existing users on the old install path are unaffected.
Both vendor asks (#27, #66) are outside our control and not blocking current
functionality.

## Housekeeping

Two design docs for now-shipped features (`createSourceFromTemplate`,
`install_fh_plugin`) were removed today — planning artifacts, no longer needed
once the work landed.

## Bottom line

Small, fast-moving project with strong test/doc discipline. One active
workstream (Windows installer packaging) and two low-priority external
dependencies. No blocking risks to current functionality.
