# FH/Lua API lookup corpora — check before probing live

Before writing/calling any `fh*`/`fhu.*` function with an uncertain signature, look up in
this order (never skip straight to live probing — `fhu`/`fh*` calls can have real side
effects, e.g. creating records, even when called "just to see the error"):

1. `server/data/fh-help-corpus.jsonl` — scraped official FH plugin API help (`fhUtils.lua`
   reference, `fh*` globals). Exact signatures, e.g. `createIndi(sName, sSex)`.
2. `server/data/gedcom-knowledge-corpus.jsonl` — concept-level domain knowledge (FTF rich
   text, Shared Facts, Source Templates, Sentence templates, "run_lua guidance" entries).
   Own JSONL file, kept separate from #1 specifically so a `check_fh_help_updates` sync
   can't overwrite it. Scope: live plugin-API-reachable concepts only — deliberately
   excludes raw exported-.ged wire-format details (`_LINK_*`/`_LKID`, `_PLAC`/`_ADDR`
   gazetteer, encoding options) since `run_lua`'s sandbox never touches a `.ged` file
   directly (ADR 0003). Each entry has a confidence tag (Verified/Confirmed/Documented/
   Likely) + source citation.
3. Web search (pluginstore.family-historian.co.uk, family-historian.co.uk/help) if neither
   corpus has it.
4. Last resort: probe live via `run_lua` — prefer functions that error on missing required
   args over ones that might execute with defaults.

Search for "name/date/place qualifiers" specifically → use `search_gedcom_knowledge`, not
grepping fh-help sample scripts (that corpus doesn't cover Data Reference qualifiers well).

## Editing gedcom-knowledge-corpus.jsonl

Use `server/scripts/corpus-entry.mjs`, not hand-rolled Python/jq one-liners — `add
<entry.json>` validates (JSON-parseable, required fields, `confidence` enum, id-uniqueness,
soft breadcrumb-family title-prefix check) then appends; `get <id>` pretty-prints one entry;
`check` validates the whole file. See ADR 0036.
