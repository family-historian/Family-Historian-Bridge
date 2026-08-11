# Notes

- User is an experienced genealogist and long-time FH user — never re-teach FH itself.
- User installs/uses the shipped MCPB package as an end user; is NOT the developer of
  this project. Keep all lessons on usage, not build/source/internals.
- Central worry driving the mission: not permanently damaging the FH database. Lean on
  this whenever introducing Read-write or any live-edit feature — always pair it with the
  actual safety mechanism (FH auto-undo/Ctrl-Z), not just reassurance.
- Lessons are opened as raw local files (not served), so Safari guesses encoding without
  a declared charset — always start every lesson HTML with `<meta charset="utf-8">` as
  the very first line, before `<title>`, or em dashes/curly quotes render as mojibake.
