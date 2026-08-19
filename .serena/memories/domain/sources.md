# Domain — Source/citation vocabulary

- **Source template**: FH template declaring possible citation fields for a SOUR record
  (e.g. "Census Record"). Distinct from a SOUR record instance's own populated fields.
  Avoid bare "Source" when the template is meant.
- **Standard citation field**: the 4 generic fields on every SOUR citation regardless of
  template — EntryDate (DATA.DATE), Assessment (QUAY), Page (PAGE), Text (DATA.TEXT).
  Text/EntryDate nest under a shared DATA child; Page/Assessment are direct citation
  children. `citeSource`'s `fields` arg exposes these under these exact reserved keys — a
  same-named template field code always loses to the reserved key (rejected as collision).
  Avoid "Generic citation field" — this project reserves "generic" for a Source template's
  generic/free-form/templated 3-way split.
- **Citation-specific field**: a Source Template field populated per-citation, not once on
  the SOUR record (its FDEF node has a `CITN="Yes"` child; record-level fields have none).
  Avoid "Record-level field" as the unmarked default — the term's point is the citation
  side of the distinction.
- **Whole-record citation**: a SOUR citation attached directly to an INDI/FAM record
  itself, not to one Fact. FH's own term. Avoid "Record citation" alone.
- **citeSource** (`bridge/sourceHelper.lua`): attaches a SOUR citation to any target
  (record = whole-record citation, or a Fact item). Resolves the source by id /
  qualified-id-string / Title (qualified-id strings always resolve as id, never Title,
  even on a same-looking Title). `fields` arg mirrors createSourceFromTemplate's, covering
  standard fields + template's Citation-specific fields; record-level template field codes
  are rejected same as createSourceFromTemplate rejects citation-specific ones. Returns a
  live item Pointer (not qualifiedId — a citation is a sub-item, not a standalone record).
  Avoid "Add source"/"link source".
- **findSources** (`bridge/sourceHelper.lua`): read-only, both Access modes. Finds SOUR
  records linked to a template matching field filters — record-vs-citation field routing
  is decided per-field by the template's own Citation-specific flag, not by the caller.
  Always returns `citedBy` (every fact/record citing each match project-wide).
- **getTemplateFieldCensus** (`bridge/sourceHelper.lua`): occurrence counts for one
  template's fields — `{recordFields, citationFields}`, every defined field present even
  at 0. `citationFields` counts citations, not distinct sources. Only pays for the
  whole-project citation walk when the template actually has a Citation-specific field.
- **GEDCOM knowledge corpus**: see `mem:corpora` for mechanics/scope. Domain-vocabulary
  point: its "Bridge project conventions" family (run_lua guidance, fhBridge API
  reference) never carries issue/ADR numbers — Git history is the record of why; the
  corpus only states what's true.
