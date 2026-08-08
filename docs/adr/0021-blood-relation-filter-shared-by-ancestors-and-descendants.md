# dnaLine gains "blood" (DnaBloodRelation) and moves onto getAncestors too

Issue #78 asked to add a blood-relatives-only option to `fhBridge`'s existing
`getAncestors`/`getDescendants` helpers (`bridge/familyHelper.lua`) — "similar to the
Mt-dna and Y-chrom checks, but using the blood relation function to weed out adopted or
other non blood children (step etc)". This ADR covers the design, building directly on
ADR 0016 (`getDescendants` defers DNA-line logic to FH's own built-ins).

**Extends the existing `dnaLine` enum with `"blood"`, rather than a new parameter.**
`getDescendants(indiPtr, maxGenerations, dnaLine)` already accepted `nil`/`"y-chrom"`/
`"mtdna"`, backed by a `DNA_LINE_BUILTIN` lookup table mapping each value to the exact
FH built-in name `fhCallBuiltInFunction` expects. FH's own `fhCallBuiltInFunction.htm`/
`fn_category_dna.html` expose `DnaBloodRelation` — "returns TRUE if two given people are
blood relations" — as exactly the same shape of pairwise check as `DnaShareYChrom`/
`DnaShareMtDna`, so it slots into the same map (`blood = "DnaBloodRelation"`) rather than
needing a separate `bloodOnly` boolean parameter. One shared map/validation path across
both helpers is simpler to reason about and test than two parallel filtering mechanisms
that would need to compose.

**The same `dnaLine` parameter (now including `"blood"`) is added to `getAncestors`,
which previously had no third argument at all.** The issue asked for the filter on both
helpers, and `getAncestors` gets the *full* enum (`"y-chrom"`/`"mtdna"`/`"blood"`), not
just `"blood"` — y-chrom/mtdna are just as meaningful walking up a tree (e.g. "is this
great-grandfather on my patrilineal line?") as walking down it, and a single shared
`DNA_LINE_BUILTIN` map/error message covering both functions is less to maintain than a
narrower enum on one side. `getAncestors`' filtering follows the exact same shape as
`getDescendants`': the full ancestor tree is still walked regardless of `dnaLine` (no
pruning of `nextFrontier`), and the filter is applied only at result-insertion time, via
`fhCallBuiltInFunction(dnaBuiltin, indiPtr, p)`.

**`DnaHalfBlood` ("half-blood") was considered and explicitly excluded.** FH's own help
page for `DnaHalfBlood` states plainly: "If one person is the direct descendant of
another, they are not 'half blood' relations." Since `getAncestors`/`getDescendants`
*only* ever walk direct ancestor↔descendant pairs, a `dnaLine="half-blood"` value would
be guaranteed to always return an empty result for these two helpers specifically — not
an edge case, a structural certainty given what they traverse. Adding it anyway (for
enum completeness with FH's DNA function family) was rejected as dead API surface that
would only confuse callers expecting it to ever match something. If a future need arises
for half-blood relatives (e.g. half-siblings, half-cousins — collateral relatives outside
a direct line), that calls for a different helper shape than these two, not this enum.

**Error message and doc comments**: `getAncestors`/`getDescendants` both now raise
`"dnaLine must be nil, 'y-chrom', 'mtdna', or 'blood' (got '<value>')"` on an invalid
value. Both functions' doc comments cross-reference each other for the shared mechanism
rather than duplicating the full DNA-builtin rationale twice.
