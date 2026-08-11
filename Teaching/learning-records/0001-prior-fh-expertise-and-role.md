# Prior expertise: experienced genealogist and FH user, MCPB end user only

The user is an experienced genealogist with many years of Family Historian use — FH's own
data model, sources, facts, and workflows do not need teaching. They will use the FH MCP
Bridge as a shipped MCPB package (installed through Claude, not built from source), and
explicitly are not the developer of this project. This means: skip FH fundamentals
entirely, skip build/install-from-source and internals content, and focus lessons on the
Bridge's behaviour layer — Sessions, Access mode, the safety model, and how to phrase
effective research questions.

## Implications
- First lessons should assume FH fluency and jump straight to Bridge-specific concepts.
- Never surface dev-facing docs (ADRs, CONTEXT.md internals about sandbox implementation,
  server source) as things to *read*, only as background I might draw on to explain
  behaviour accurately.
