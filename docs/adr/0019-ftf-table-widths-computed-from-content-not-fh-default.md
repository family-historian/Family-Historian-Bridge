# FTF table column widths are computed from cell content, not FH's flat 800-twip default

Issue #76: FTF tables (`<table="w1|w2|...">`, per the `ftf-tables` corpus entry) require an
explicit width per column in twips. Prior practice, visible in the worked example carried in
`server/src/runLuaTool.ts`'s history and this project's own git log, was every column at a flat
800 twips, matching FH's own documented default for an omitted/empty width. That's a fixed
guess independent of what's actually in the cell: a column of single-digit years and a column of
full sentences got the same width, so short columns wasted space and long columns truncated or
wrapped.

## Decision

Every `run_lua` script that builds an FTF table computes each column's width from its own
content: `width = ceil(max_chars_in_column / 0.011) + 200` twips, no separate minimum-width
floor, the 200-twip padding term is what keeps a narrow (e.g. single-digit) column from
collapsing to zero, rather than a `min_width` constant forcing it back up to some fixed floor
regardless of content. `0.011` chars-per-twip assumes a standard proportional font (Arial/Times
New Roman-class); no monospace handling. This is written into the `ftf-tables` corpus entry
(`server/data/gedcom-knowledge-corpus.jsonl`) as guidance for Claude to apply inline in each
script, not as a `familyHelper.lua` sandbox helper, see "Considered and rejected" below.

Separately, and recorded here because it was decided alongside the width formula: when a table
would be the very first content in a rich-text field, the script inserts a blank paragraph line
above it. Without one, there's no way to place the cursor above the table later when editing that
field in FH's own rich-text UI, this is an editing-ergonomics fix, not a rendering bug, and
applies to every rich-text field the bridge writes to, not just Notes.

### Constants are a ballpark, not a measured font metric

`0.011` and `200` come from issue #76's write-up, which reasoned from assumed font metrics and an
eyeballed 22/22 pass on real transcriptions, not from measuring FH's actual rendered output. A
content-aware guess beats a fixed guess even when the guess itself is unrefined; refining the
constant against real FH rendering later is possible without changing the shape of the formula.

### Considered and rejected

- **Keep the issue's `min_width = 300` floor.** Rejected: a floor re-introduces the same
  content-blindness this decision exists to remove for the case it matters most, a column that's
  genuinely short (single digits, short codes) shouldn't be padded past what its content needs.
  It's also lower than FH's own 800-twip default for an omitted width, which would have made the
  floor case look narrower than what FH does automatically if no width were given at all, a
  contradiction not worth carrying forward.
- **Centralize the formula as a `familyHelper.lua` sandbox helper**, matching the precedent of
  `getAncestors`/`getDescendants`/etc. Rejected: those helpers earn their centralization by
  wrapping non-trivial, easy-to-get-subtly-wrong logic (BFS traversal, pedigree-collapse dedupe,
  deferring DNA-line rules to FH's own built-ins per ADR 0016), the kind of thing worth getting
  right once. A one-line arithmetic formula doesn't carry that risk, so a helper would centralize
  for consistency's sake alone, which isn't what the existing pattern is for. Inline arithmetic
  also costs Claude only a couple of extra lines per table-building script, unlike a genuine
  traversal a script would otherwise have to reimplement badly.

## Consequences

- `server/data/gedcom-knowledge-corpus.jsonl`'s `ftf-tables` entry carries the formula and the
  leading-blank-line rule as the operational recipe; this ADR is the record of *why* those
  specific choices (no floor, ballpark constants, no helper) were made.
- The constants are expected to need tightening once real FH-rendered tables are compared against
  them, nothing about this decision blocks that; only the formula's shape (content-driven, no
  fixed floor) is meant to be durable.
