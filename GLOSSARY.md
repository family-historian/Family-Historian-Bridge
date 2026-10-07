# FH MCP Bridge

An MCP server, installable alongside Family Historian (FH), that lets Claude query and
edit a user's open FH project by sending Lua scripts to a companion FH plugin over a
local TCP socket.

## Domain glossary moved to Serena memories

This file's full glossary (Session, Access mode, Sandbox, run_lua, describe_project,
Source template, FTF, Shared Fact, Fact/Record Flag, findSources, getTemplateFieldCensus,
logActivity, etc.) now lives in `.serena/memories/domain/*`, split by topic — see
`mem:core` for the index and which cluster covers what.

**New domain terms go there, not here** — add a `domain/*` memory (or extend an existing
one) rather than re-growing this file. Full design history/rationale for a term still
lives in `docs/adr/` and this repo's Git history, same as before.
