# describe_project's flagCensus is Individual-record-flags only; dataQuality is a namespace for future checks

Issue #51 asked `describe_project` to break `_FLGS` down by specific flag (rather than the
single aggregate count `tagCensus` already gave it) and to surface a data-quality signal for
Individuals whose "no death record" is ambiguous rather than confidently "living".

**flagCensus scope.** FH has two distinct flag mechanisms sharing an implementation
mechanism (see the GEDCOM knowledge corpus's `fact-flag-vs-record-flag` entry): Record
Flags (Individual-only, 2 built-in — Private/Living — plus unlimited custom ones) and Fact
Flags (attached to a specific fact — Individual or Family — 4 built-in, plus custom). The
issue's own motivating example (`__LIVING`/`__PRIVATE`) is entirely about record flags. We
scoped `flagCensus` to record flags only, walking each `INDI`'s own `_FLGS` child one level
deep. Fact flags would need walking every fact of every INDI/FAM record looking for a
nested `_FLGS` — a materially bigger traversal the script doesn't do anywhere else today —
and nothing in the issue asked for it. Left for a follow-up issue if it turns out to be
wanted.

**flagCensus shape.** `{ "<tag>": { "count": <n>, "label": "<name>" } }` — count and label
merged under one key per flag tag, rather than two parallel top-level objects. The tag is
the natural join key either way; merging avoids two same-shaped objects a consumer would
just have to re-zip, and avoids the two ever drifting out of sync with each other.

**Flag label resolution.** The issue also asked for custom flag *names*, not just tags, but
found no read-only way to get one: `fhGetFlagTag(name, false)` only maps a known name to
its tag — even after issue #51's separate `fhGetFlagTag` fix, it's a one-way lookup that
needs the name as input, not an enumeration. We found `fhGetTypeInfo(ptr, "label")` — a
function already available in `run_lua`'s Read-only sandbox, unrelated to `fhGetFlagTag` —
that returns the display label of *any* item, including a flag instance under `_FLGS`. So
`flagCensus` resolves each tag's label from one flag instance the first time that tag is
seen, at no extra sandbox permission cost.

**dataQuality as a namespace, not a bare top-level key.** `livingStatusAmbiguousCount` is
a data-quality flag, not a census of something observed the way `recordCounts`/`tagCensus`/
`flagCensus` are — and the issue frames "living status ambiguous" as one example of a class
of check (data gaps a naive query would silently get wrong), not the only one anticipated.
`describe_project`'s response now has a `dataQuality` object so a future check like this
has an obvious home, rather than every future addition landing as another unrelated
top-level key.
