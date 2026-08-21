# fhGetRecordLinks replaces manual link scans in sourceHelper.lua

Issue #66 tracked an upstream request for a function to return record links, closed when
`fhGetRecordLinks` shipped in FH8 (wired into the sandbox allowlist by issue #134).
`findSources`/`getTemplateFieldCensus` in `sourceHelper.lua` each had a manual, whole-
project scan doing the same job by hand; this pass replaces both with `fhGetRecordLinks`.

`fhGetRecordLinks(ptr)` is **item-level**, live-confirmed against a running Bridge: given a
target record, it returns the specific items that link to it — e.g. a SOUR record's own
`_SRCT` child, or a Fact-nested citation's `SOUR` item — at whatever depth they live, not
resolved up to their owning record. (An earlier draft of this ADR assumed the opposite,
record-level-only shape; live-testing against the Sample Project corrected that before this
landed.) `MoveToParentItem`/`MoveToRecordItem` climb from a returned item to its enclosing
Fact/record when that's what a caller needs.

Decisions:

1. **Template → citing SOUR records** (`findSources`/`getTemplateFieldCensus`'s outer
   loop). Replaced the whole-SOUR-table walk + `linkedTemplate(sourPtr) == templateId`
   check with `fhGetRecordLinks(template)`: each returned item is the citing SOUR record's
   own `_SRCT` child, so `MoveToRecordItem` climbs straight to the SOUR record. Tag-guarded
   (`fhGetTag(sourPtr) == "SOUR"`) and deduped by record id, defensively.
2. **SOUR → citing items, for fact-level citation detail** (`collectCitations`/
   `allCitationsBySourceId`, replaced entirely by `citationsForSource`). `findSources`'s
   `citedBy` and the census's citation field counts need the specific citation item (for
   `matchesFilters`' shortcut-Data-Reference field resolution) and its enclosing Fact's own
   tag (e.g. "BIRT", not "SOUR"). `fhGetRecordLinks(sourPtr)` returns each citation item
   directly; `MoveToParentItem` gives the enclosing Fact/record's tag, `MoveToRecordItem`
   gives the owning INDI/FAM's qualifiedId. No tree-walk of any kind remains — the old
   whole-project scan is gone outright, not just bounded.
