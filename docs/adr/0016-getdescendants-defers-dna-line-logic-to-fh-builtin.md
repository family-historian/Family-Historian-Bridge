# getDescendants mirrors getAncestors; DNA-line filtering defers to FH's own built-in functions

Issue #63 (empirically testing the MCP against a set of example researcher questions)
surfaced that `fhBridge`'s family/detail query helpers (`bridge/familyHelper.lua`)
support upward and lateral traversal from an Individual, `getFamilyGroup(ptr,
"parents"|"siblings"|"spouses"|"all")` and `getAncestors(ptr, maxGenerations)`, but
nothing downward. Filed as #64. This ADR covers the fix.

**Shape: a straight mirror of `getAncestors`, not a new pattern.** `getDescendants(ptr,
maxGenerations)` is the same breadth-first walk as `getAncestors`, just down `FAMS`/
`CHIL` instead of up `FAMC`/`HUSB`/`WIFE`, with the same optional generation cap and
the same pedigree-collapse-style dedupe (a descendant reachable via more than one path,
cousins who married, say, is reported once, at its shallowest generation). No
"children" relationship type was added to `getFamilyGroup` separately:
`getDescendants(ptr, 1)` already covers that case, and one implementation serving both
needs is simpler than two.

**`line` entries are "son"/"daughter", not `getAncestors`' "father"/"mother".** A
`CHIL` item carries no role of its own the way a `FAMC` record's `HUSB`/`WIFE` link
does, so there's no direct mirror of `getAncestors`' role label. Recording each step's
own `SEX` instead ("child" if unrecorded, rather than erroring, a descendant list
shouldn't fail outright over one person's sex never having been entered) turned out to
be exactly the input the DNA-line filter below needs, so it wasn't a completely free
choice of label, but it's also the only piece of per-step information that's actually
meaningful for a `CHIL` step.

**DNA-line filtering (`dnaLine: "y-chrom"|"mtdna"`) calls FH's own
`DnaShareYChrom`/`DnaShareMtDna` via `fhCallBuiltInFunction`, not a hand-rolled
son/daughter-only tree prune.** The user supplied a real prior plugin of theirs
("Create and Update Ancestor and Descendant Counts") as a reference for the traversal
shape, and separately asked for a Y-chromosome/mitochondrial option, noting FH has
built-in DNA functions. `fhCallBuiltInFunction` (already granted, unconditionally, in
`sandbox.lua`'s read-only environment, it's a pure fetch, not a write) turned out to
expose exactly `DnaShareYChrom`/`DnaShareMtDna`/`DnaBloodRelation`/`DnaHalfBlood`/
`DnaRelatedness`/`DnaOverlapXChrom`, FH's own pairwise DNA-relationship functions
(`/help/fh8/fn_category_dna.html`, `fhCallBuiltInFunction.htm`). Working out the
son/daughter propagation rules by hand was a real option, FH's own help pages state
them plainly enough (Y-chromosome: father to son only; mitochondrial: mother to all
children, but only daughters propagate it onward), but deferring to FH's own
authoritative implementation is safer than this module re-deriving genealogical rules
itself: any edge case FH's own implementation accounts for (however it treats an
unclear sex, an adoptive FAMC, etc.) is inherited for free, rather than this module
needing to notice and match it independently. `getDescendants` still walks the *full*
descendant tree regardless of `dnaLine`, the filter is applied per-node at result-
insertion time, not used to prune `nextFrontier`, trading some wasted traversal on a
branch that can no longer match (e.g. everything under a daughter, once `dnaLine` is
`"y-chrom"`) against not having to reason about whether a prune rule and the built-in's
own filter could ever disagree. Fine at this project's typical tree sizes; worth
revisiting only if a very large/broad tree's `getDescendants(..., "y-chrom")` call
turns out to cost noticeably more than the unfiltered call.

**No preemptive error when `dnaLine` can't possibly match indiPtr's own sex** (e.g.
`"y-chrom"` against a female `indiPtr`). `DnaShareYChrom`/`DnaShareMtDna` themselves
just return `false` for every such pair per FH's own docs, never erroring, matching
that behaviour (an empty result, not a raised error) keeps `getDescendants` consistent
with what the built-in it's delegating to would say, rather than this module deciding
a call like that was actually a mistake worth stopping over.
