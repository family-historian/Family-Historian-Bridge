# Mission: Using the FH MCP Bridge for genealogy research

## Why
I'm an experienced genealogist and long-time Family Historian user. I want to use Claude,
via the FH MCP Bridge, to answer research questions directly against my live FH project
and, eventually, to help me record findings into the database — without risking permanent
damage to years of accumulated research data.

## Success looks like
- I can run my regular source-entry workflow — transcribe, create the Source record, add
  or update the facts/people it supports, cite it against them — through the Bridge, and I
  know exactly where its current limits are (e.g. citation-specific template fields).
- I can start a Bridge Session in FH, choose the right Access mode, and ask Claude
  natural-language research questions grounded in my actual open project.
- I know exactly what "Read-only" guarantees and what "Read-write" allows, and can
  articulate why a mistake in either mode is recoverable (FH auto-undo, Ctrl-Z, backups).
- I have a personal safety routine (e.g. backup-before-Read-write) I trust enough to use
  Read-write sessions for real record-keeping, not just lookups.
- I can judge whether an answer "looks right" and know how to ask Claude to show its work
  when it doesn't.
- I can get Claude to write me a standalone FH plugin for a repeatable task, when that's a
  better fit than an ad hoc live question.

## Constraints
- I am an end user of the shipped MCPB package — not a developer of this project. Teaching
  should stay on the "how do I use this" side, not the source/build/internals side.
- I already know Family Historian deeply (data model, sources, facts, GEDCOM). No need to
  re-teach FH itself — only the Bridge's behaviour layered on top of it.
- Sessions with FH need the Bridge Session actually running to try things live; some
  lessons may need to be "read this, then go try it in FH" rather than fully interactive.

## Out of scope
- Building or modifying the Bridge plugin / MCP server source code.
- FH's own core genealogy features/UI, except where the Bridge changes how they behave
  (e.g. main window locking during a Session).
