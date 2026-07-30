# Cite every fact a source supports, and offer a shared citeSource helper

Working a real certificate (case: Nellie Record's birth certificate, Source #41) showed
two gaps in how this project handles sources. First, only the Fact the user explicitly
asked about (Nellie's `BIRT`) got a citation — the same certificate also names her
parents and states her father's occupation, none of which were cited or even entered,
until asked separately. Second, the citation itself was hand-rolled five separate times
in one session (`fhCreateItem("SOUR", target)` + `fhSetValueAsLink`) — once per Fact/
record — repeating a pattern `sourceHelper.lua` already exists to avoid for template-
based Source *creation* (`createSourceFromTemplate`).

Decisions:

1. **Steer this from `run_lua`'s tool description, not a Skill.** A Skill (`SKILL.md`) is
   Claude-Code-only and wouldn't travel with the MCP server to another host. `run_lua`'s
   description is part of the MCP protocol response itself, so it reaches Claude
   regardless of client — the same reasoning already applied to the FH-help-corpus
   search-order fix. No Skill was added; the description is the single source of truth.
2. **Add `fhBridge.citeSource(ptrTarget, sourceIdOrTitle)`** to `sourceHelper.lua`,
   resolving the source the same by-id-or-by-title way `createSourceFromTemplate`
   resolves a template, rather than requiring the caller to already hold a `SOUR` pointer.
   One tested code path replaces the hand-rolled two-liner.
3. **Always list gaps and wait for confirmation before writing them.** When a source is
   cited, `run_lua`'s description now asks Claude to read the source's transcription,
   compare it against what the record already has, and report anything the source
   supports that isn't yet entered — then wait for the user's go-ahead before adding it.
   This matches the project's existing stance on creator functions (no dry-run, undo is a
   manual Ctrl-Z): the safer default is proposing writes, not making them silently on the
   strength of the original request alone.
