# Edit inside an existing RichText field via a full-document tFTF rewrite, not an extended eFTF record-links table

Issue #107 (mid-document RichText edit) and its prerequisite issue #106 found that FH's own
documented way to splice new content into an existing rich-text field — `GetText()` a
field, extend its `sText`/`tblRecLinks` with new `<rec=N,...>` tags and matching table
entries, `SetText()` it back — is broken beyond an exact, unmodified passthrough:
`tblRecLinks` is not a general-purpose table a caller can freely construct or extend; any
hand-extension returns `false` silently (live-tested twice against Family Historian Sample
Project 8). `AddText`/`AddRecordLink` on a live-fetched RichText object works, but only
appends to the *end* of the object's current content — neither approach can reach a
specific existing line partway through a large field.

**Decision.** `fhBridge.getTftfText`/`fhBridge.setTftfText` (`bridge/richTextHelper.lua`)
solve the record-link case by using tFTF instead of eFTF for the rewrite: tFTF's
`<rec=QualifiedId,...>` syntax embeds the target record's own qualified id directly in the
text, so `RichText:SetText(text, true, true)` needs no side table at all — it structurally
cannot hit the #106 bug, because there is no table to break. `getTftfText` converts a
field's `GetText()`-returned eFTF text (index-based `<rec=N,...>` + `tblRecLinks`) into a
self-contained tFTF string; a caller edits that plain string with ordinary Lua operations —
anywhere in the document, including a brand-new record link mid-document — and
`setTftfText` commits the whole thing in one rewrite. Live-verified against Family
Historian Sample Project 8 (2026-08-15 grilling session): a two-record-link document,
rebuilt with a new link spliced into the middle, round-tripped correctly through a real
`fhSetValueAsRichText` write and a fresh `fhGetValueAsRichText` re-read; reusing an
already-linked record's qualified id in a second tag correctly deduped to one table entry,
matching FH's own documented behavior.

**The trade-off, and why it's a real one.** tFTF cannot represent source citations at all —
this is FH's own documented limit on the syntax, not a gap in this implementation. Worse,
confirmed live in the same session: `SetText(text, true, true)` does not error on text
containing a `<cit=N>` citation marker. It silently accepts it, the marker becomes dead
literal text, and the citation is gone with no warning — FH provides zero protection here.
Both functions refuse outright whenever a field's own `GetText()` reports any embedded
citations, rather than risk that silent loss; `setTftfText` re-checks at write time too, in
case a citation was added by hand in FH's own UI between a `getTftfText` call and the
matching `setTftfText`. There is currently no known citation-safe equivalent of this
technique — mid-document editing of a citation-bearing field's interior remains an open
problem, deliberately out of scope here (see the corresponding
`run-lua-guidance-mid-document-richtext-edit` family in the gedcom-knowledge-corpus). Use
eFTF/`AddCitation` directly for citation work, or ask the user to edit that field by hand in
FH.
