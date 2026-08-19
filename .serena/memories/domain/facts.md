# Domain — Fact/record vocabulary

- **createFact** (`bridge/factHelper.lua`): creates a Fact on INDI/FAM via `fhu.createFact`.
  `ptrRecord` accepts a live Pointer or qualified-id string, never a bare number (spans
  both INDI/FAM, a number alone can't disambiguate). Returns the new Fact's live Pointer
  (sub-item, not a standalone record) — chain into `citeSource` in the same run_lua call.
  Never touches Source/citation itself — citing is always a separate step. `dtDate`
  accepts a Date object, `{year=,month=,day=[,subtype=]}` table, or a plain string (parsed
  via FH's own Date parser, resolved through `familyHelper.resolveDate` before any write —
  unrecognized strings reject before the Fact item is created). Avoid "Add fact".
- **Shared Fact**: a Fact with participants beyond its own record (other household
  members, a wedding's best man). Each participant has a free-text `ROLE` (not an enum),
  and either resolves to a Person or is name-only. Avoid "Witness" — that's a Shared
  Fact's participant role, not a separate mechanism.
- **Fact Flag** vs **Record Flag**: distinct mechanisms sharing some names. Record Flag
  marks a whole Individual (2 built-in: Private, Living). Fact Flag marks one Fact (4
  built-in: Private, Preferred, Tentative, Rejected — Rejected always overrides Preferred
  on the same fact). Both support unlimited custom flags. A "Private" of each kind is
  always distinct even on the same person. Never say "Flag" alone without which kind.
- **Direct ancestor**: everyone reachable walking *all* of a person's FAMC links upward
  (not just a "primary" one — FH has no reliable primary-line field), no generation limit
  unless the user specifies one, excludes the named person. Avoid "Ancestor" alone when
  this FAMC-only walk specifically is meant.
- **Qualified id string**: letter-prefixed record id (e.g. "I219", "F3", "S1186") — tag
  prefix (F=FAM, I=INDI, O=OBJE, N=NOTE, R=REPO, S=SOUR, U=SUBM, B=SUBN, P=_PLAC, E=_RNOT,
  T=_SRCT) + numeric `fhGetRecordId`. Distinct from a bare id number (no tag, can't
  disambiguate type). Always resolved as an id, never attempted against Title/NAME, even
  on a same-looking Title. Most fhBridge helpers accept one as an alternative to a live
  Pointer.
- **Clarifying question**: on ambiguous natural-language scope (unspecified generation
  depth, ambiguous place spelling), ask the user rather than silently guessing and running
  a run_lua script against the guess.
