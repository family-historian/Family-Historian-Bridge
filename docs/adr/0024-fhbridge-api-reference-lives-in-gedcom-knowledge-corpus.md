# fhBridge API reference lives in the GEDCOM knowledge corpus, under Bridge project conventions

Issue #102: none of `fhBridge`'s 12 functions (`familyHelper.lua`/`sourceHelper.lua`/
`sessionLogHelper.lua`) had a reference entry anywhere a live session could search, unlike raw
`fh*` globals (fh-help corpus's "Function Index" page) or `fhu.*` methods (also fully documented
in fh-help, just missing an index — fixed instead by a discoverability-only doc change, no new
corpus content, mirroring the earlier `fh*` Function Index fix).

Considered three homes for the 12 new entries: (A) a new breadcrumb family inside the existing
`gedcom-knowledge-corpus.jsonl`, reusing `search_gedcom_knowledge`/`grep_gedcom_knowledge`
as-is; (B) a new sibling JSONL file merged in-memory with that corpus at load time; (C) a
wholly new corpus file plus a dedicated `search_bridge_help`/`grep_bridge_help` tool pair,
mirroring the fh-help/gedcom-knowledge pattern a third time.

Chose (A). The corpus already carries a `"Bridge project conventions"` top-level breadcrumb
family (`"run_lua guidance"`, 13 entries, `confidence: "Verified"`, sourced from this repo's
own files) — first-party Bridge documentation, not GEDCOM/FH domain facts, despite the file's
name. A new `"Bridge project conventions" > "fhBridge API reference"` family is a direct
extension of that existing precedent, not a scope violation of ADR 0003 (that ADR excludes
exported-`.ged`-file wire format specifically, not first-party Bridge content generally). (C)
was rejected on the same grounds a prior grilling session rejected a new tool for the analogous
`fh*` gap (see CHANGELOG "FH help corpus sync and Function Index discoverability"): more tools
to remember to check is the class of problem issue #102 reports, not a fix for it. (B) was
rejected as unnecessary complexity — 12 entries fit comfortably in the existing corpus's byte
budget, and (A) needs no new load-path code at all.

No separate index entry for fhBridge (unlike `fh*`'s "Function Index"): 12 functions already
fit in a single `grep_gedcom_knowledge` call (cap 25) via their shared breadcrumb, so a second,
duplicate summary entry would add drift risk with no discoverability win. Entries are compact
(Description/Parameters/Returns, matching the existing fhu.md-derived entries' style) — no
design history, issue numbers, or examples — since they're read by a token-budget-sensitive
end-user session needing a callable signature, not a repo developer researching *why*; that
audience distinction is also why CONTEXT.md's existing prose glossary entries for these same
functions are left as-is rather than cross-referenced. A new test asserts the corpus's
`fhBridge` entry names exactly match `sandbox.lua`'s `env.fhBridge` keys, so an undocumented
13th function fails a test rather than silently repeating this issue.
