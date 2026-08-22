# findByNames replaces searchByName: free-text, batch, and NAME:FULL

Issue #137 asked for a batch variant of `fhBridge.searchByName(forename, surname)` — a
certificate/source transcription typically needs to resolve 4-6 people in one call, not
4-6 separate `searchByName` calls. Its comment separately asked for word-order-insensitive
matching ("Issac Crabb" should also match "Crabb Issac"). Live usage also showed the real
failure mode driving both asks: agents mostly don't use the two-argument `(forename,
surname)` shape correctly — they pass a single full-name string into `forename`, which
silently fails to match anything containing a surname, since `~.NAME:GIVEN_ALL` never
includes it.

**`searchByName` is replaced outright, not kept alongside a new function.** Pre-1.0, and
the two-arg shape is actively mismatched to how it's actually called — a new function
sitting next to a broken one wouldn't fix the broken one's misuse. `fhBridge.searchByName`
is removed from `familyHelper.lua`/`sandbox.lua` and all docs/corpus/tests; `findByNames`
takes its place under `fhBridge`.

**`findByNames(query, exactMatch)`** — `query` is a single plain-text name string, or an
array of them for one batch call; `exactMatch` is an optional boolean, default `false`,
scoped to the whole call (not per-entry — mixing modes in one batch was judged not worth
the shape complexity). Matching is **word-set containment**: `query` is split on
whitespace, and every resulting word must independently match, case-insensitive, against
`~.NAME:FULL` — a **Verified** Data Reference qualifier confirmed via
`search_gedcom_knowledge` ("the complete name", distinct from `STORED`, which is the raw
GEDCOM slash-delimited form). Default mode matches each word as a substring anywhere in
`NAME:FULL`; `exactMatch` requires each word to equal a whole word in it exactly. Order
never matters, on either side.

**One field (`NAME:FULL`) replaces the old two-field `GIVEN_ALL`+`SURNAME` AND test.**
`searchByName`'s original design deliberately used the two split qualifiers instead of raw
`NAME` text, to dodge per-record slash/formatting inconsistency — that reasoning still
holds, but `NAME:FULL` gets the same benefit (it's a resolved qualifier, not raw text) while
also fixing the full-name-as-one-string failure mode outright: a multi-word query no longer
needs to land entirely within the given-names portion.

**Ranking ("best match first")**: a query word that exactly equals a whole name-word
outranks one that only matched as a substring; ties break by which candidate's overall
`NAME:FULL` is closer in length to the query (fewer unmatched extra characters). A third
signal considered — "more query words matched outranks fewer" — was dropped: since every
returned result already satisfies word-set containment (100% of query words matched, by
definition of being included at all), that signal could never actually differ between two
ranked results.

**Results are capped at the top 30 per search, reported honestly.** At real-world scale
(400k+ individuals in some projects, and searches like "William Williams" that can
legitimately match dozens in a Welsh-heritage tree), an uncapped word-set match needs a
limit. Rather than a silent slice, each search's result is `{matches: [...], totalMatches:
N}` — `matches` holds up to 30 ranked entries, `totalMatches` the true count before capping.
This follows the precedent set a day earlier by issue #135's `search_gedcom_knowledge` fix:
a limit cut is always reported honestly, never silent.

**Output shape mirrors input shape.** A single `query` string returns one `{matches,
totalMatches}` object; an array of queries returns an array of that same shape, one per
input entry, in input order — a no-match entry stays at its position (empty `matches`,
`totalMatches: 0`) rather than being dropped, so a caller resolving several names from one
document can tell exactly which ones didn't resolve. `jsonEncode.lua` has no way to mark an
empty Lua table as an array, so an empty `matches` crosses the wire as `{}`, not `[]`.

**Validation**: any blank (`""`/`nil`) entry — the single `query`, or any item in the list —
errors the whole call. There's no longer an "omit this half, keep the other" fallback the
way the old two-argument form had (an empty `forename` skipped just that filter); a blank
free-text entry has no other field to fall back to, and matching "everyone" silently is
never what a name-resolution batch caller wants.

**Implementation walks the `INDI` table once per call, not once per query.** A naive port
of the old per-call full-table-walk would multiply it by list length; at large-project
scale that turns one already-noticeable scan into several. Every query is tested against
each record as it's visited in a single pass.
