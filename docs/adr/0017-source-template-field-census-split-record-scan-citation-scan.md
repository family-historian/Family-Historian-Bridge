# describe_project's sourceTemplateFields becomes structural-only (definitions, not occurrence counts); occurrence counting moves to a new on-demand fhBridge helper

Issue #74: `describe_project`'s `sourceTemplateFields` census (issue #67/#73's own fix)
only ever tallied *record-level* template field occurrence — a Citation-specific field
(FDEF's own `CITN` child) is populated per-citation, not on the `SOUR` record itself, so it
silently reported zero for every such field. In the reporting project, `Specific_Item` (a
`CITN` field) is populated on 1,108 of 1,196 citations — one of the most-used fields in the
project — yet never appeared in the census at all, which is actively misleading for a tool
whose whole purpose is telling Claude the project's actual shape before it writes a script.

**Why not just extend the existing walk to cover citations too.** The obvious fix — reuse
`sourceHelper.lua`'s `allCitationsBySourceId`/`collectCitations` (already proven correct via
`findSources`, issue #73) to also tally citation-level occurrence — would make every
`describe_project` call recursively walk every citation on every `INDI`/`FAM` record in the
project. `describe_project` recomputes on every call with no caching (ADR 0002) specifically
because it's meant to be a cheap, look-once-at-the-start survey; a full citation walk is
categorically heavier than today's per-record-type child tally and the per-`SOUR`-record
field resolution, and that cost lands on every conversation whether or not it ends up
touching sources at all.

**What we did instead.** `sourceTemplateFields` (renamed `sourceTemplateFieldDefinitions`)
becomes a structural-only listing: walk the project's `_SRCT` template records and their
`FDEF` children directly (cheap and bounded by template count — FH only copies templates
that have actually been used into the project, so this stays small regardless of how many
Individuals/Sources/citations the project has), reporting every field's own `CODE`, `TYPE`,
and `CITN` flag, nested per template rather than flattened across all templates (two
different templates can reuse the same field code with different meanings, so flattening
without a template key would be actively misleading now that there's no occurrence count to
disambiguate by). This alone closes the visibility gap issue #74 raised — a citation-scoped
field now shows up, correctly labeled, at zero cost beyond what the fixed census already
does elsewhere.

All occurrence counting — record-level (the issue #67/#73 walk this ADR removes from
`describe_project`) and citation-level (the walk this ADR declines to add there) — moves to
a new opt-in `fhBridge.getTemplateFieldCensus(templateNameOrId)` helper, following the same
single-template shape as `findSources`/`getPopulatedTemplateFields`, returning
`{ recordFields = {code = countOfSourRecordsPopulated}, citationFields =
{code = countOfCitationsPopulated} }`. This is built now against today's
`collectCitations`/`allCitationsBySourceId` machinery, not held back for FH's own upcoming
faster record-lookup build — the cost concern that ruled this walk out of the fixed census
doesn't apply here, since this helper only runs when a caller actually wants field-usage
data for one template, and the stable `fhBridge.getTemplateFieldCensus` signature can absorb
a faster implementation later without any caller-visible change once that build lands.
