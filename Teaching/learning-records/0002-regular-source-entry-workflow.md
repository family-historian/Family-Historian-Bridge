# Regular task disclosed: transcribe → create source → add facts → cite

The user's most regular real-world task is: transcribing a source, creating the Source
record, adding/updating people and facts based on it, and citing the source against them.
This is now the concrete anchor for the mission, not an abstract "record findings" goal —
future lessons on Read-write usage should default to this workflow's shape rather than a
generic edit example.

## Implications
- The Bridge supports this end to end via `sourceHelper.lua`'s `createSourceFromTemplate`
  (transcription stored as rich text, record-level fields only) and `citeSource`
  (Whole-record or Fact-level), plus ordinary Read-write record/fact editing.
- **Status: closed, as of issue #99 (2026-08-11), superseding the note below.**
  Citation-specific Source Template fields (populated per-citation, e.g. a GRO Index's
  Registration District) can now be set — `citeSource(ptrTarget, sourceNameOrId, fields)`
  takes an optional `fields` table covering both the 4 standard GEDCOM/FH citation fields
  (Page/Text/EntryDate/Assessment) and a template's own citation-specific (CITN) fields,
  in the same call that creates the citation. A reserved standard-field name always wins
  over a same-named template field, rejected as a clear collision.
  ~~Previously (through issue #98): only the *failure mode* had improved (silent no-op →
  clear error on `createSourceFromTemplate`); the underlying capability was open and
  untracked.~~ Re-verify against `bridge/sourceHelper.lua` before teaching this again in
  case it drifts further — this file changes fast.
- `citeSource` is steered to compare the transcription against what's already entered and
  propose (not silently add) anything the source supports beyond the original ask — worth
  reinforcing as the reason this workflow doesn't need a separate "did I miss anything"
  step.

## Note on the correction itself
On 2026-08-11 the user twice pushed back accurately on stated capability of this project
mid-session — once believing a gap was closed when it wasn't yet (confirmed via the
Forgejo issue tracker, not just git log), then again shortly after when it genuinely had
been (confirmed via a fresh `git fetch` + diff review). Lesson: for a fast-moving project
like this one, re-check the actual current state every time rather than trusting what was
true earlier in the same session.
