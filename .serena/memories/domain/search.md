# Domain — name search vocabulary

- **findByNames** (`bridge/familyHelper.lua`, replaces `searchByName` — ADR 0037): takes
  `query` (a plain-text name string, or an array of them for a batch call) and an optional
  `exactMatch` boolean (whole-call scope, not per-entry; a non-boolean errors, to catch the
  old two-string `searchByName(forename, surname)` habit). Matches via **word-set
  containment**: `query` split on whitespace, every word independently matched
  case-insensitive against `~.NAME:FULL` (substring by default, exact whole-word under
  `exactMatch`), order never significant. Single haystack (`NAME:FULL`), not the old
  `GIVEN_ALL`+`SURNAME` split.
- **Word-set containment**: the match rule above — *every* query word must be found, so a
  returned result always has 100% of query words matched by definition (this is why a
  "count of matched words" ranking signal was rejected as dead weight — it can never
  differ between two results that are in the result set at all).
- **Result shape**: each search's result is `{matches: [...], totalMatches: N}` — `matches`
  capped to the top 30 ranked, `totalMatches` the true pre-cap count (never a silent slice,
  same honesty precedent as issue #135's `search_gedcom_knowledge` fix). Output shape
  mirrors input shape — one object for a single `query` string, an array of that shape (one
  per entry, position-preserving, no-match entries kept with empty `matches` and
  `totalMatches: 0`) for a list. Wire note: `jsonEncode.lua` can't mark an empty Lua table
  as an array, so an empty `matches` crosses as `{}`, not `[]` — deliberate, project-wide,
  not a findByNames-specific gap.
- **Ranking**: exact-word match outranks substring-only match; ties break by closer overall
  `NAME:FULL` length to the query.
