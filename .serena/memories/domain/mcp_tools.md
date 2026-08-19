# Domain — MCP tool behaviors

(File/module layout: `mem:server`. This covers domain semantics only.)

- **run_lua**: the only query/write entry point — a freshly-authored script per call, no
  fixed command set. Avoid "Query tool"/"command".
- **describe_project**: fixed built-in script (not Claude-authored), always runs Read-only
  regardless of Session's Access mode, recomputed every call (no cache, ADR 0002). Returns
  record/tag census, `sourceTemplateFieldDefinitions` (structural only — occurrence counts
  live in `getTemplateFieldCensus` instead), `flagCensus` (Individual record flags only,
  not Fact Flags), `dataQuality.livingStatusAmbiguousCount`, `contextInfo` (9 string/bool
  `CI_*` keys — excludes HWND light-userdata keys and report-only book-context keys),
  `fhAppVersion`, `bridgeState` (bridgeVersion/serverVersion/versionStatus/accessMode,
  merged from the same VERSION exchange, no second connection). Unknown fields are `null`,
  never omitted.
- **author_fh_plugin**: scaffolds a standalone Report/Query `.fh_lua` plugin, returned as
  text for the user to save. Report gets `@Type: report` + `FH_GetRecordSectionContent`
  wrapper; Query gets neither (no required header/entry-point in FH's own architecture).
  Distinct trust model from run_lua: never executed by the Bridge, runs under FH's own
  trust once installed — functions run_lua's sandbox excludes (fhShellExecute, filesystem,
  fhMessageBox, fhPromptUserFor*, fhOutputResultSet*) are fair game here, but flagged
  inline in the output.
- **install_fh_plugin**: writes an author_fh_plugin output into FH's Plugins folder. Never
  auto-chained after author_fh_plugin — only on explicit user request (ADR 0008). Resolves
  the folder via a live Session's `CI_APP_DATA_FOLDER` (falls back to confirmed `path`).
  Never overwrites — next unused `V<N>` suffix on filename and `@Title`. Writes via the MCP
  server's own filesystem access (not through the Bridge/sandbox), UTF-8 with leading BOM.
