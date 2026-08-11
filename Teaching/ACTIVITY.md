# Activity Log

A running log of what happened each session — separate from `learning-records/`, which
only captures decision-grade insights (not routine coverage). This is the session-by-session
journal: what was set up, what was taught, what's pending.

## Session 1 — 2026-08-11

- Set up the teaching workspace from scratch: `MISSION.md`, `RESOURCES.md`, `NOTES.md`,
  `assets/style.css`, `assets/quiz.js`.
- Established (learning-records/0001): user is an experienced genealogist and long-time FH
  user, using the shipped MCPB as an end user (not the developer) — lessons stay on usage,
  not internals/build.
- Wrote **Lesson 1 — Sessions & the safety model** (`lessons/0001-sessions-and-safety.html`):
  Session lifecycle, Access mode (Read-only vs Read-write), and the real safety mechanism
  (FH's own Ctrl-Z/auto-undo — the Bridge adds no undo logic of its own).
- Fixed: lessons are opened as raw local files, so Safari mis-guessed encoding on em
  dashes/curly quotes — added `<meta charset="utf-8">` as the first line; now a standing
  rule in `NOTES.md` for every future lesson.
- Next up: Lesson 2, on asking effective research questions in Read-only mode.

## Session 1 (cont.)

- Wrote **Lesson 2 — Asking trustworthy research questions**
  (`lessons/0002-asking-trustworthy-questions.html`): no fixed command list, orienting
  with a project-overview census first, why custom Fact types resolve correctly (fresh
  script per question), and the "ask Claude to double-check/explain" verification habit
  for answers that look wrong.
- User confirmed Lessons 1 and 2 done; moved on to Lesson 3.
- Wrote **Lesson 3 — Your first Read-write session**
  (`lessons/0003-first-read-write-session.html`): a concrete 4-step routine (back up,
  state the edit precisely, watch it happen then verify in FH yourself, deliberately test
  Ctrl-Z once) — turns Lesson 1's safety theory into practice before a real edit is at
  stake.
- Next up: Lesson 4 — likely getting a standalone plugin written (the non-live-Session
  path), a natural next step now the live-Session basics (research + edit) are covered.

## Session 1 (cont. 2)

- Wrote **Lesson 4 — Getting a standalone plugin written for you**
  (`lessons/0004-standalone-plugins.html`): live question vs. standalone plugin (when to
  reach for each), why a generated plugin isn't bound by Access mode, the
  `-- FLAGGED` comment review habit as the safety mechanism in this path, and how to
  install (manual vs. asking Claude, including the V2/V3 versioning behaviour).
- Next up: Lesson 5 — open; the live-Session (research + edit) and generated-plugin paths
  are both now covered end to end. Candidates: interleaved practice mixing Read-only
  research, Read-write edits, and plugin requests; or wait for the user's next real
  research/edit need and build a lesson around it.

## Session 1 (cont. 3)

- User asked directly whether the Bridge can help with their most regular task:
  transcribe a source, create the Source record, add/update facts and people, cite the
  source. Answered from the actual code (`bridge/sourceHelper.lua`,
  `docs/adr/0006-cite-every-fact-a-source-supports.md`), not just docs — confirmed yes,
  end to end, with one real current gap: citation-specific Source Template fields (e.g. a
  GRO Index's Registration District) can't be populated by the Bridge at all yet, at
  source-creation or citation time.
- Recorded (learning-records/0002): this workflow is the user's real, regular task —
  future Read-write lessons should default to its shape. Flagged the citation-specific-
  field gap as something to re-verify before ever teaching around it, in case it's fixed
  later.
- Updated `MISSION.md`'s "Success looks like" to name this workflow concretely.
- Wrote **Lesson 5 — The source-entry workflow**
  (`lessons/0005-source-entry-workflow.html`): the four-step walkthrough (create source
  + transcription in one step, add/update facts, cite with the built-in
  "propose what's missing, wait for go-ahead" behaviour, and the citation-specific-field
  gap), plus the automatic per-Session Research Note activity log as a review trail.
- Next up: open. The core mission (research, safe editing, plugins, and now the specific
  regular source-entry workflow) is covered. A natural Lesson 6 candidate is a hands-on
  walkthrough of the citation-specific-field workaround in FH itself, if the user hits a
  template that needs it — otherwise, wait for the next real need.

## Session 1 (cont. 4)

- User believed the citation-specific-field gap had been closed; checked directly against
  the Forgejo issue tracker (issue #98) rather than assuming. Confirmed the lesson was
  right: #98 only changed the failure mode (silent no-op → clear error on
  `createSourceFromTemplate`), not the underlying capability — actual citation-specific
  field population remains open/untracked per the issue's own closing comment.
- Tightened Lesson 5's danger box to state that distinction explicitly (fix to the error
  behaviour, not the capability), since the previous wording was apparently easy to misread
  as "recently fixed" in the wrong direction.

## Session 1 (cont. 5)

- User reported the fix had now genuinely been pushed. Verified fresh via `git fetch` +
  `git show` (issue #99, commit 9f147b0) and cross-checked the Forgejo issue's closed
  state, rather than trusting the earlier session's finding — `citeSource` now takes a
  `fields` argument covering the 4 standard citation fields (Page/Text/EntryDate/
  Assessment) plus a template's own citation-specific (CITN) fields, in the same call that
  creates the citation. Confirmed genuinely closed, not just a friendlier error this time.
- Rewrote Lesson 5's Step 4 from a "known gap" danger box to a "now supported" safety box,
  updated the quiz and the "Try it now" steps to match, and updated
  learning-records/0002 with the corrected status plus a note-to-self: re-verify this
  file's state each time before teaching it again, since it's changing fast this session.
