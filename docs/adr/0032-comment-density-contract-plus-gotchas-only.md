---
status: accepted
---

# Comments: contract + load-bearing gotchas only, drop narration

`bridge/*.lua` comments had drifted toward narrating *how the code came to be* — issue-number
references, ADR citations that added nothing beyond the pointer, "confirmed live" anecdotes,
considered-and-rejected asides — stacked on top of the actual function contract. Reviewed and
trimmed across all bridge modules (issue #121): 13 files, ~750 net lines of comment removed,
no behavior changes, existing test suites unaffected.

## Decision

A function/module comment keeps only:
- **The contract**: what it does, its params, its return value/shape.
- **Load-bearing gotchas**: a real behavioral quirk that would cause a bug if someone "fixed" it
  without knowing — a non-obvious ordering requirement, a silent-failure mode, a positional
  argument coupling, a platform/API quirk that isn't visible from reading the code alone.

Drop everything else: bare issue-number references, ADR citations where the citation itself adds
nothing beyond what the code already says, "confirmed live"/live-tested narration, and
considered-and-rejected design rationale. A pointer to an issue or ADR stays only when the pointer
*is* the load-bearing fact — e.g. "per ADR 0006, a Fact-level citation is a deliberately different
target, not a bug" is load-bearing; "(issue #45)" tacked onto an otherwise self-explanatory line
is not.

Rationale/history that's worth keeping at all belongs in the ADR for that decision (`docs/adr/`),
not in the code comment — the comment can cite the ADR when the citation itself is load-bearing.

## Consequences

- Applies to new comments too, not just the existing trim — this is the convention going forward,
  not a one-time cleanup.
- When editing a comment for an unrelated change, trim it toward this convention if it's already
  wordy; no separate pass required.
