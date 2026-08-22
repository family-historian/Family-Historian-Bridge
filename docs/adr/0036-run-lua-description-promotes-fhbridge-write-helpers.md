# run_lua description promotes fhBridge helpers over fhu/raw fh*, write helpers included

Live usage kept showing hand-rolled `fh*`/`fhu` code (`fhSetValueAsLink` plumbing,
manual RichText `SetText`, manual citation record-links) in places `fhBridge` already had a
purpose-built helper for — including write paths (`createFact`, `citeSource`,
`createSourceFromTemplate`, `getTftfText`/`setTftfText`), not just the read-only
family/detail query helpers `RUN_LUA_DESCRIPTION` already named. The description's opening
didn't mention `fhBridge` at all, and the one write-helper callout that existed
(`logActivity`) was narrower than the pattern actually needed fixing.

Decisions:

1. **Helper-precedence order is now explicit and inline, up front**: search first, always
   — `fhBridge`'s purpose-built helper before `fhu`, `fhu` before hand-rolling
   `MoveToFirstRecord`/`MoveNext` or a raw `fh*` write. This replaces an earlier
   read-only-only helper callout with one line covering both read and write helpers by
   name.
2. **A hard write-gate**: before any write-mode script, fetch the write-helper reference
   (`createSourceFromTemplate`, `getTftfText`/`setTftfText`, `logActivity`) via
   `search_gedcom_knowledge("run_lua guidance")` if not already fetched this task. Framed as
   a gate, not a suggestion — an unlogged write gets rolled back, not just warned about,
   same reasoning as ADR 0011 point 2's "call once regardless" framing, extended from
   "call it" to "call it before you write."
3. **The full write-helper contract moved corpus-only**, as a new entry
   `run-lua-guidance-write-helpers`, alongside the existing read-only
   `run-lua-guidance-family-query-helpers` survey entry (same breadcrumb family, same
   `"run_lua guidance:"` title prefix, so one `search_gedcom_knowledge("run_lua guidance")`
   call still surfaces both). This is a deliberate escalation past ADR 0011 point 4, which
   left `logActivity`'s paragraph inline specifically because its enforcement wasn't
   confirmed to live in the sandbox yet. It now does (`runScript.lua`'s
   `tracker.wrote`/`tracker.logged` check, `attemptRollback` on a mismatch) — the inline
   description's job shrank to naming the gate and pointing at the corpus entry, not
   restating logActivity's own contract, because a caller who skips the read still hits the
   real rollback and its error, not silent data loss.
4. **Byte budget stayed the binding constraint, not character count.** `runLuaTool.test.ts`
   asserts `Buffer.byteLength(RUN_LUA_DESCRIPTION, "utf8") < 1950`, and UTF-8 multi-byte
   characters (em-dashes) make that a tighter ceiling than `.length` suggests. Fitting the
   above required trimming the ambiguity-resolution and truncation-notice paragraphs and
   naming only `createFact`/`citeSource` inline (the two most commonly hand-rolled), leaving
   `createSourceFromTemplate`/`getTftfText`/`setTftfText`/`logActivity` to the corpus entry.
   The truncation-notice sentence itself was reframed around "this content is corpus-only by
   design" rather than leading with the truncation caveat — cheaper in bytes, same
   guarantee.
5. **`server/scripts/corpus-entry.mjs` added** (`add`/`get`/`check`) as the supported way to
   edit `gedcom-knowledge-corpus.jsonl` going forward, replacing ad hoc Python/jq one-liners.
   Serena's `replace_content` can't safely insert a new JSONL entry — there's no symbol
   boundary to anchor an insertion on, and neither Serena nor a raw text edit checks
   id-uniqueness, JSON-validity of the resulting line, or the `confidence` enum before it
   lands in the file. The script validates all of that (plus a soft breadcrumb-family
   title-prefix check) before writing, and `get` reads a single entry back out for
   inspection without hand-editing the file.

This is additive to ADR 0011's safe-zone/corpus-deferral pattern, not a reversal of it: the
safe zone still exists and is still the guaranteed-survives content, it now leads with
`fhBridge` precedence and a write-gate instead of a read-only helper callout, and detailed
write-helper contracts join the same corpus-deferred tier the read-only helpers and gotcha
catalog already occupied.
