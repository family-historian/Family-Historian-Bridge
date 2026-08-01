# run_lua description truncation: safe zone plus corpus-deferred content

A user testing issue #40's session-log feature on a fresh Claude instance found it never
called `fhBridge.logActivity` at all — not a partial miss, a full no-show. Asking a second
Claude instance (a different MCP client) to check its own copy of `run_lua`'s tool
description found the actual mechanism: that client's deferred/lazy tool-schema loading
(`ToolSearch`) truncates long tool descriptions at a hard limit around 2KB, appending a
literal `[truncated]` marker, with no error surfaced anywhere. Reproduced directly against
this project's own `run_lua` tool: querying for it alone, with no other tool in the same
call, still truncated at the same point.

`RUN_LUA_DESCRIPTION` was 11,007 characters. The cutoff landed at character 2,048 — over
80% of the description, past "fhUtils... already has a purpose-built helper for exactly
th…", was invisible to any client using this loading path. That's not just the
`logActivity` paragraph: the entire call-shape gotcha catalog, the `citeSource`
gap-listing/confirmation guidance, and the `writeSessionRolledBack`/auto-undo explanation
were all past the cutoff too.

This is a limitation in the client-side tool-loading layer, not a bug in this project's
code — there's nothing in this repo that could fix `ToolSearch` itself. What this project
does control is the content and ordering of the description it hands to any client.

Decisions:

1. **Split `RUN_LUA_DESCRIPTION` into a safe zone and corpus-deferred content.** The first
   ~1800 characters (intro, Session requirement, clarifying-question guidance, a condensed
   search-first/prefer-`fhu` mandate, and a truncation notice) are self-sufficient and
   comfortably clear of the observed ~2048-character cutoff. Everything else that was
   previously inline — the call-shape gotcha catalog, `citeSource` guidance, and
   `writeSessionRolledBack` handling — moved into `server/data/gedcom-knowledge-corpus.jsonl`
   as three new entries (`run-lua-guidance-call-shape-gotchas`,
   `run-lua-guidance-cite-every-fact`, `run-lua-guidance-write-session-rolled-back`), reusing
   the existing corpus rather than adding a new tool.
2. **The safe zone explicitly tells Claude the description may be truncated**, and to call
   `search_gedcom_knowledge("run_lua guidance")` once near the start of any conversation
   that will use `run_lua`, regardless of whether the rest of the description looks
   complete. This works because truncation is specific to *tool schema descriptions*
   loaded ahead of invocation — a tool's *result*, returned once it's actually called, goes
   through a different path and isn't subject to the same limit (confirmed empirically:
   `grep_fh_help` results many KB long came back intact in the same session that reproduced
   the `run_lua` truncation).
3. **The three new entries all share the literal title prefix `"run_lua guidance:"`**, so
   the single query `"run_lua guidance"` matches all three via `corpusSearch.ts`'s
   title-substring rank (guaranteed top rank, no dependence on the token-overlap fallback),
   and are returned in full — `search_gedcom_knowledge` returns complete entry text, not an
   excerpt (see `gedcomKnowledge.ts`'s own comment on this).
4. **`logActivity`'s own paragraph was left untouched and in place, not corpus-deferred.**
   Its steering still lives partly past the safe zone and is still subject to truncation —
   deliberately not band-aided here, since the actual fix under discussion is moving that
   behavior into the sandbox itself (`sandbox.lua`/`sessionLogHelper.lua`) so it no longer
   depends on any instruction surviving at all, truncated or not. Relocating its text now
   would be wasted work if that redesign changes it significantly.
5. **`SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION` itself was updated** to mention the new
   `"run_lua guidance"` query so the tool's own advertised scope stays consistent with what
   it now returns — checked afterward that the added sentence lands well within that
   description's own safe zone, not past its tail end.

This reduces `RUN_LUA_DESCRIPTION` from 11,007 to 3,527 characters. It doesn't eliminate
the underlying truncation risk (a client could still enforce a stricter limit, and the
gotcha catalog itself is long enough that a *second* truncation past the safe zone's own
end is still possible for a client with a smaller budget) — but it guarantees the
highest-priority rules survive, and gives every client an explicit, truncation-immune path
to the rest via a tool call rather than a schema field.
