# Handoff: testing & consolidation review

**Written:** 2026-08-10, against `main` @ `5f1439f` (version 0.11.0, working tree clean).
**Status:** picked up 2026-08-10. Everything below is now tracked as a Forgejo issue, and
items 1–3 of the suggested order are done. The analysis is kept as written, including the
one place it turned out to be wrong (see the release.md note below).

| Finding | Issue | State |
|---|---|---|
| Unified test runner | [#84](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/84) | **done** |
| Finding 1 — manifest tool-list drift | [#85](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/85) | **done** |
| `docs/release.md` stale | [#86](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/86) | **done** |
| Finding 2 — `corpusSearch` untested | [#87](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/87) | open |
| Finding 3 — `bridgeSession.lua` split | [#88](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/88) | open (deferred by design) |
| `@Version:` header injection | [#89](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/89) | open |
| No CI | [#90](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/90) | **pre-push hook done; CI declined** (`wontfix`) |
| No coverage | [#91](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/91) | open |
| ESLint recheck | [#92](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/92) | open |
| Stale `installer/` artifacts | [#93](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/93) | open |

**Correction to the release.md finding.** This document says anyone following `release.md`
"hand-builds a zip while ignoring the automation", implying steps 6–7 were obsolete. They
weren't: the hand-assembled `fh-mcp-bridge-X.Y.Z.zip` is the artifact actually attached to
every Forgejo release, including 0.11.0 — the `release-mac.sh` / `release-windows.ps1`
outputs have never been released. The real problem was narrower and stranger than described:
the scripted path and the released path build *different artifacts*, and the doc documented
only one of them while denying the other existed. `release.md` now says so explicitly.

This is a survey of the repo's test setup and the consolidation opportunities found
alongside it, written up so the work can be picked up later without repeating the
investigation. Findings are ranked; each one records what was actually verified, so you
don't have to re-check the easy parts.

---

## Baseline: everything passes today

All three suites were run on 2026-08-10 and were green. This is a consolidation job, not a
rescue job.

| Suite | Runner | How it's run | Result |
|---|---|---|---|
| `server/src/*.test.ts` (9 files) | vitest 4.1.10 | `cd server && npm test` | 196 passed, ~500ms |
| `bridge/tests/*.test.lua` (12 files) | plain `lua` | one file at a time | 12/12 passed |
| `installer/dxt/manifest.test.mjs` | `node --test` | `node installer/dxt/manifest.test.mjs` | 8 passed |

Reproduce all three:

```bash
cd server && npm test && cd .. && for f in bridge/tests/*.test.lua; do echo "== $f"; lua "$f" || break; done && node installer/dxt/manifest.test.mjs
```

Source sizes for context: `server/src` ≈ 1,850 lines of implementation + ~2,600 of tests;
`bridge/*.lua` ≈ 2,990 lines + 3,577 of tests; `installer/*.mjs` ≈ 434 lines.

---

## The structural problem: three runners, no aggregate

Three separate test runners with three invocation styles, and no single command runs them
all. `npm test` in `server/` — the only one that looks like a project-wide test command —
covers roughly a third of the tested surface.

Two specific consequences:

- **No aggregate bridge runner.** The Lua tests must be looped over by hand. This is
  already recorded in the Serena memory `suggested_commands`: *"No aggregate 'run all'
  script observed; run each file individually or loop over `bridge/tests/*.test.lua`."*
- **`installer/dxt/manifest.test.mjs` is wired into nothing.** Verified by grep: it is
  referenced by no npm script, not by `installer/release-mac.sh`, not by
  `installer/release-windows.ps1`, and not by `docs/release.md`. The only mentions are a
  usage comment in its own header and two prose references in
  `docs/adr/0015-mcpb-bundle-manifest-is-generated-not-hand-copied.md`. It passes today
  only because nobody has broken it — a release can be cut with it failing and nothing
  would say so.

**Proposed fix.** A root-level `package.json` (or `Makefile` — no strong preference; the
repo root currently has no manifest of either kind) exposing:

- `test:server` → `cd server && npm test`
- `test:bridge` → loop `bridge/tests/*.test.lua` through `lua`, failing on first non-zero exit
- `test:installer` → `node --test installer/dxt/`
- `test` → all three

Then add the aggregate `test` to the top of `release-mac.sh` and `release-windows.ps1`, so
a release cannot be built over a failing suite.

**Effort:** small (~30 min). **Do this first** — it's the prerequisite that makes every
other item below verifiable.

---

## Finding 1 — the manifest tool-list test is tautological

**Where:** `installer/dxt/manifest.test.mjs:110`, with the hardcoded list at
`installer/dxt/manifest.test.mjs:49`.

The test is named *"buildManifest lists every tool server/src/index.ts currently
registers, and no others"*. It does not do that. It compares `buildManifest()`'s output
against `EXPECTED_TOOL_NAMES`, a literal array declared in the test file itself.
`server/src/index.ts` is never read, imported, or parsed.

So: add a ninth tool to the server, and this test still passes while the `.mcpb` manifest
silently under-declares it. The failure mode is a shipped bundle that doesn't advertise a
tool it actually has.

This is *known but understated*. ADR 0015 acknowledges the drift, and
`installer/verify-dxt.mjs:30` describes itself as *"a third copy of the same acknowledged
drift"*. The problem is the test's **name**, which asserts a guarantee it doesn't provide —
that's worse than having no test there, because it reads like coverage during review.

**Why it isn't a one-line fix.** The tool names don't live in `index.ts` as a list. That
file just calls `registerRunLuaTool(server)`, `registerDescribeProjectTool(server)` and so
on (see `server/src/index.ts:37-54`); each name string lives inside its own
`register*Tool` function. A grep for the eight names across `server/src/*.ts` finds 14
literal occurrences. There is no list to parse.

**Two viable fixes:**

1. **Export a shared constant.** One `TOOL_NAMES` (or a small name→description map)
   exported from the server and consumed by the `register*Tool` functions,
   `installer/dxt/manifest.mjs`, and `installer/verify-dxt.mjs`. Collapses four copies to
   one. Requires the installer scripts to import from `server/dist/`, which is a new
   coupling — check that works for the `.mcpb` build order.
2. **Assert against the real server.** Have the test (or `verify-dxt.mjs`) spawn the built
   server over stdio and call `tools/list`, comparing that to the manifest. Stronger
   guarantee, slower test, and `verify-dxt.mjs` already does something structurally
   similar so there's a pattern to follow.

Current tool count is 8: `run_lua`, `describe_project`, `author_fh_plugin`,
`install_fh_plugin`, `search_fh_help`, `grep_fh_help`, `check_fh_help_updates`,
`search_gedcom_knowledge`.

**Effort:** small-to-medium. **Worth doing second.** If nothing else is done, at minimum
rename the test so it stops overclaiming.

---

## Finding 2 — `corpusSearch.ts` has no direct test

**Where:** `server/src/corpusSearch.ts` (117 lines). No `corpusSearch.test.ts` exists.

This is the entire ranking engine behind both `search_fh_help` and
`search_gedcom_knowledge` — `tokenize`, `tokenMatchScore`, `buildExcerpt`, `searchEntries`,
plus the tuning constants `TITLE_TOKEN_WEIGHT`, `TEXT_TOKEN_WEIGHT`,
`BREADCRUMB_TOKEN_WEIGHT`, `STOPWORDS`, `TOKEN_MIN_LENGTH`, `EXCERPT_RADIUS`.

It is exercised only indirectly, via `fhHelp.test.ts` and `gedcomKnowledge.test.ts` (both
import `searchEntries` transitively through `fhHelp.ts:6` and `gedcomKnowledge.ts:5`).
Nothing asserts on the weights or the stopword list directly. Search-quality regressions —
a changed weight, a stopword added — are precisely the kind that pass every existing test
while making results worse.

Worth pinning: relative ordering when a term hits title vs. body vs. breadcrumb; stopword
exclusion; the `TOKEN_MIN_LENGTH` cutoff; excerpt windowing around a match, including at
the start/end of a text.

`server/src/bridgeResponse.ts` (84 lines: `describeBridgeConnectionError`,
`interpretBridgeResponse`, `isLuaErrorShape`, `isStalePrototypeHandshake`, `textResult`)
is the same situation — no direct test file, covered incidentally through
`versionCheck.test.ts` and the tool tests. Lower stakes than `corpusSearch`, but the same
gap.

**Effort:** small-to-medium. Good candidate to pair with turning on vitest coverage
reporting (see Minor items), which would replace the estimate above with a measurement.

---

## Finding 3 — `bridgeSession.lua` is the largest untested module in the repo

**Where:** `bridge/bridgeSession.lua`, 411 lines. No `bridge/tests/bridgeSession.test.lua`.

Every other bridge module has a test. This one doesn't, and it's the biggest. It holds
real policy logic, not just plumbing:

- `currentAccessMode`, `statusColorForMode`, `currentIdleTimeoutSeconds`,
  `updateTimeLeftLabel`
- `stopSessionIfRunning` / `confirmAndStopSession` — including the
  `RECENT_ACTIVITY_CONFIRM_SECONDS` freshness-confirm rule from
  `docs/adr/0020-exit-button-shared-teardown-freshness-confirm.md`

The blocker is that this logic is interleaved with IUP widget construction at file scope
(`lblStatus`, `togReadOnly`, `radAccessMode`, `dlg`, `timPoll` are all created as the file
loads), so `require`ing it from a plain-`lua` test would need an IUP stub.

**Proposed fix:** a second split — pure session-state/policy module vs. the IUP wiring —
following exactly the reasoning
`docs/adr/0018-split-bridge-entry-file-into-stub-and-bridgesession.md` already applied once
to the entry file. That would make ADR 0020's confirm-before-stop rule testable, which
matters because it's user-facing behaviour that could silently regress and is currently
only caught by manual testing inside FH.

**Effort:** medium — a genuine refactor with an ADR to write. **Recommendation: defer**
until you're touching that file for another reason, then do it as part of that work.

---

## Minor items

- **`docs/release.md` is stale and actively misleading.** Its steps 6–7 describe
  hand-assembling and zipping the release folder, and its Risks section states *"No full
  packaging script exists."* That is no longer true: `installer/release-mac.sh` and
  `installer/release-windows.ps1` now do it. Verified by grep — release.md mentions
  neither script, and never mentions the `.mcpb`/dxt flow at all (its only installer
  reference is `stage.ps1`, at line 43). Anyone following release.md today hand-builds a
  zip while ignoring the automation. Fixing this is cheap and prevents a wasted release.

- **Version bump is in better shape than release.md claims.** Its step 4 says three
  independent hand-maintained copies. In reality `server/src/serverVersion.ts` already
  reads `package.json` at runtime (issue #44), and `stage.ps1` generates the `.iss`
  version. The only genuinely hand-maintained *second* copy left is the `@Version:` header
  in `bridge/Claude MCP Bridge.fh_lua:5`. Having `bridge/scripts/build.lua` inject it from
  `server/package.json` when it builds the bundle would close that permanently.
  (`package-lock.json`'s two occurrences are fixed by `npm install`, not by hand.)

- **No CI.** No `.github/`, no `.forgejo/`. Solo project, so this is a judgement call —
  but with three runners and no aggregate command, even a local `pre-push` hook running
  the new unified `test` target would be worth having.

  *Resolved 2026-08-10:* the hook was built; CI was declined. A Forgejo Actions workflow
  was written, pushed, and backed out on learning the infrastructure — Forgejo runs on a
  small LXC, and all development happens on one Mac. CI's only advantage over the hook is
  catching a `--no-verify` push or a clone that never ran `npm run setup:hooks`, neither of
  which applies to a single developer on a single machine. Backing it out also stopped
  every push queueing a workflow run that no runner would ever pick up.

- **No coverage measurement.** vitest ships coverage; nothing is configured. Findings 2
  and 3 above are informed reading, not measurement — coverage would confirm or correct
  them.

- **~250 MB of gitignored build artifacts** under `installer/`: `output/` 69M (still holds
  0.6.0 and 0.7.0 `.exe` and `.mcpb` files next to 0.11.0), `staging/` 91M, `cache/` 35M,
  `dxt-staging/` 27M, `mac-staging/` 27M. All correctly gitignored — `git ls-files
  installer/` shows only the 11 real source files. Pure housekeeping, no risk.

- **ESLint still absent.** The auto-memory records this as deliberately deferred: `server/`
  pins `typescript@^7` and typescript-eslint capped at `<6.1.0`. Re-check whether that's
  still true before assuming it — that note may have aged out.

---

## Suggested order

1. **Unified test runner** — prerequisite for everything else, ~30 min.
2. **Finding 1**, the tool-name drift — closes a real correctness gap in shipped bundles.
3. **`docs/release.md` refresh** — cheap, and it's currently the most misleading doc here.
4. **Finding 2**, `corpusSearch` tests (+ coverage reporting).
5. **Finding 3**, `bridgeSession` split — defer until that file needs touching anyway.

Items 1–3 together are roughly an hour and make everything after them safer.

## Open questions — answered 2026-08-10

- **Root `package.json` or `Makefile`?** Root `package.json`, private and with no `version`
  field so it can't become a second version source. The bridge loop lives in
  `scripts/run-bridge-tests.mjs` (Node, not a shell loop) because the release scripts run it
  from PowerShell on Windows too.
- **Finding 1: shared constant or spawn-and-`tools/list`?** Both, and they turned out to be
  complementary rather than alternatives. `server/src/toolNames.json` is the shared source
  all three consumers read; `server/src/toolNames.test.ts` gets the stronger guarantee
  cheaply by standing up an `McpServer` over `InMemoryTransport` in-process — no built
  bundle needed, so it runs in the normal unit suite. `verify-dxt.mjs` still does the
  real-bundle spawn on top of that.
- **Forgejo issues?** Yes — all ten filed, #84–#93.
