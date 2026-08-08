# FH/Lua API lookup order

Before writing or calling any `fh*`/`fhu.*` function whose exact signature you're unsure of
(param order, types, required-vs-optional), check in this order — never skip straight to
probing live via `run_lua`, since `fhu`/`fh*` calls can have real side effects (creating
records) even when called "just to see the error message":

1. `server/data/fh-help-corpus.jsonl` — scraped FH plugin API help (`fhUtils.lua` reference,
   `fh*` global functions). Has exact signatures like `createIndi(sName, sSex)`.
2. `server/data/gedcom-knowledge-corpus.jsonl` — concept-level domain knowledge (FTF rich
   text, Shared Facts, Source Templates, Sentence templates). See ADR 0003 for its scope.
3. Web search (`pluginstore.family-historian.co.uk`, `family-historian.co.uk/help`) if
   neither corpus has it.
4. Only as a last resort, probe live via `run_lua` — and even then, prefer functions that
   error on missing required args over ones that might execute with defaults.
