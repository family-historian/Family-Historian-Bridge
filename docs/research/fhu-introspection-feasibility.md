# Feasibility: detecting `fhu`/module calls to risky globals via introspection, without executing them

Research ticket: [issue #29](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/29),
part of map [issue #28](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/28).
Feeds the (separate, HITL) mechanism-decision ticket #30 — this document does not decide
anything, it only answers the feasibility question.

**Note on location**: this repo has no existing "research notes" convention (`docs/`
only has `docs/adr/`, `docs/agents/`, `docs/superpowers/`), so this file was placed at
`docs/research/` as a new sibling.

## Verdict, up front

**Partially feasible as a runtime/dev-time capability, but not worth building.** The
pieces exist (Lua's `debug` library, bytecode disassembly, source parsing all really can
detect *direct* references to a named global like `iup` or `file` without calling the
function that contains them). But every technically-feasible route either (a) requires
already having a live, loaded function value — which for `fhUtils.lua` means running
inside FH's own Lua host with its C bindings (`iup`, `cd`, `im`, Penlight) present, not a
portable dev-time script — or (b) reduces to source-text/AST analysis, which this repo
already has a working, deliberately-imprecise precedent for
(`server/src/authorFhPluginTool.ts`'s regex flagger). Given `fhUtils.lua` is ~41 methods,
changes only when FH ships a new version (infrequent, human-noticed event), and a
one-time hand-read audit already happened (#22) and is captured as a static list in
`bridge/sandbox.lua`, building an automated re-classifier is solving a problem that
doesn't recur often enough to amortize the cost of building and maintaining bespoke
tooling — a scoped grep/AST pass, re-run by a human the next time FH ships a `fhUtils`
update, is the pragmatic answer. See [§6](#6-verdict-and-reasoning) for the full
reasoning.

---

## 1. What Lua version does FH's plugin host run?

**Lua 5.3.5**, confirmed directly from FH's own shipped help content
(`server/data/fh-help-corpus.jsonl`, entry `/help/fh8plugins/New_in_Version_7.htm`,
"Plugin Enhancements in Version 7"):

> "Family Historian plugins are written in Lua and use Lua components. Version 7 now uses
> an updated version of Lua and related components. The new versions are: **Lua 5.3.5**,
> CD 5.12, IUP 3.28, IM 3.13."

A second corpus entry (`/help/fh8plugins/lua/convert-5.1-5.3-lua.html`, "Converting Lua
5.1 Plugins to Lua 5.3") corroborates this and documents the 5.1→5.3 migration FH's own
plugin authors had to do (patterns escape character, `table.unpack` replacing `unpack`,
`arg` table removal, `string.gfind`→`string.gmatch`), all of which are exactly the
Lua-5.2-then-5.3 language changes — internally consistent with "Lua 5.3.5" being accurate,
not a typo for 5.1.

**This is stock (PUC-Rio) Lua, not LuaJIT.** LuaJIT has never implemented Lua 5.3
language semantics — it is "based on Lua 5.1 syntax, with some optional support for
5.2/5.3 features" but does not implement the 5.3 language as a whole (LuaJIT project
page, [luajit.org/extensions.html](https://luajit.org/extensions.html); corroborated by
community discussion, e.g.
[Hacker News: "Isn't LuaJIT stuck on Lua 5.1?"](https://news.ycombinator.com/item?id=15650546)).
Since FH's own help explicitly states "Lua 5.3.5" as a specific patch version (not "5.1
with extensions"), and documents full 5.3 semantics (the `_ENV`-based global model,
`table.unpack`, integer/float subtypes implied by the 5.1→5.3 migration guide), this is
confidently the reference/PUC-Rio implementation, version 5.3.5 exactly — this is a strong
confidence-level claim, not a guess, given it's a direct quote from FH's own documentation
rather than an inference.

**Confidence: high** (direct primary-source quote, internally corroborated by a second
independent corpus entry).

---

## 2. Can the `debug` library detect referenced globals/upvalues without calling the function?

**No — not directly, and not by name.** The `debug` library can inspect *metadata about*
a function value without calling it, but none of its facilities enumerate "which global
names does this function's bytecode reference."

- **`debug.getinfo(f, what)`** ([Lua 5.3 manual §6.10](https://www.lua.org/manual/5.3/manual.html#6.10))
  returns a table describing a function: `source`, `what` ("Lua"/"C"/"main"),
  `linedefined`, `nparams`, `nups` (**count** of upvalues), etc. It tells you *how many*
  upvalues a function has, never their names or what globals they resolve.

- **`debug.getupvalue(f, index)`** ([§6.10](https://www.lua.org/manual/5.3/manual.html#6.10))
  returns the *name and current value* of the `index`-th upvalue of a Lua closure `f`,
  without calling `f`. Since Lua 5.2, every function that references a global does so via
  an implicit `_ENV` upvalue (see §3) — so `debug.getupvalue` **can** tell you a function
  has an `_ENV` upvalue and hand you the live environment table it points to. But it
  cannot tell you *which keys of that table* the function's body actually indexes (`iup`,
  `file`, `fhCreateItem`, ...) — that information lives in the function's bytecode, not in
  the upvalue list. Also: "Lua does not let you see or change upvalues for C functions"
  (mirrored manual text, e.g. [gammon.com.au Lua doc mirror](https://www.gammon.com.au/scripts/doc.php?lua=debug.getupvalue))
  — irrelevant for `fhUtils.lua` itself (a Lua module) but relevant if you tried to
  introspect `iup.Popup` itself (a C function) rather than the caller that references it.

- **`debug.sethook`** ([§6.10](https://www.lua.org/manual/5.3/manual.html#6.10)) registers
  a hook fired on `"call"`/`"return"`/`"line"`/`"count"` events — but only *while the
  hooked function is actually running*. This project already uses `debug.sethook` for
  exactly this reason, in `bridge/watchdog.lua`, to interrupt runaway scripts on an
  instruction-count hook — precedent that the `debug` library is available and already
  relied on in this codebase, but for a fundamentally different purpose (bounding
  execution of code that *is* running), not static pre-execution analysis. A `sethook`
  approach to this ticket's question would require actually calling the target function to
  observe its hook events, which is precisely what the ticket asks to avoid.

**Conclusion**: `debug.getinfo`/`debug.getupvalue` can confirm a function *has* an `_ENV`
upvalue (i.e., *could* reference globals) but cannot enumerate *which* globals, without
either calling the function or going one level deeper into its bytecode (§3).

**Confidence: high**, direct manual citations plus one already-fetched secondary mirror
corroborating exact wording.

---

## 3. Can bytecode disassembly reveal referenced global names statically?

**Yes, in principle — a compiled Lua 5.3 function's bytecode directly encodes referenced
global names as string constants next to `GETTABUP`/`SETTABUP` instructions.**

Since Lua 5.2, global variable access compiles to `GETTABUP`/`SETTABUP` against the
implicit `_ENV` upvalue, replacing the pre-5.2 `GETGLOBAL`/`SETGLOBAL` opcodes (Lua 5.2
manual §8.1, "Incompatibilities... Global variables cannot ... be manipulated by
`GETGLOBAL`/`SETGLOBAL` anymore; instead you access them through the `_ENV` upvalue" —
`www.lua.org/manual/5.2/manual.html#8.1`; FH's own help corpus references this exact
section, see §1 above). Confirmed concretely from a Lua-5.3-specific bytecode reference
([Ravi language docs, Lua 5.3 Bytecode Reference](https://the-ravi-programming-language.readthedocs.io/en/latest/lua_bytecode_reference.html)):

> `GETTABUP A B C   R(A) := UpValue[B][RK(C)]` — "These instructions are used to access
> global variables, which since Lua 5.2 are accessed via the upvalue named `_ENV`."
>
> Example: compiling `a = 40; local b = a` disassembles to
> `SETTABUP 0 -1 -2 ; _ENV "a" 40` then `GETTABUP 0 0 -1 ; _ENV "a"`.

So `luac -l -l fhUtils.lua` (or `string.dump` on an already-loaded function, fed to a
disassembler) would show, for e.g. `getParam`, a `GETTABUP`/`GETFIELD` sequence
referencing the constant strings `"iup"` and `"Popup"` — directly answering "does this
function call `iup.Popup`" **without ever calling `getParam`**.

**Two practical obstacles make this route weaker than it first looks, specific to this
codebase:**

1. **`string.dump` requires a live, already-loaded Lua function value** — you can't
   disassemble bytecode you don't have. Getting that live value means either (a) running
   `luac` directly against the `.lua` *source file* (no live Lua process needed — `luac`
   compiles source itself), which works, or (b) `require('fhUtils')` inside a running Lua
   5.3 process and then `string.dump()` the resulting function values, which requires the
   module's top-level `require(...)` calls for `iup`, `cd`/`im`, Penlight, etc. to
   succeed — i.e., a real FH process (or a faithful stub of its C bindings), not a bare
   `lua5.3`/`luac` install on a dev machine. Note also `string.dump` only works on **pure
   Lua functions**, erroring on C functions (manual: "the function must be a Lua
   function" — confirmed via mirrored 5.1-era text and corroborated by 5.3 behavior notes
   that C functions cannot be dumped, e.g.
   [lua-users.org DumpingFunctionsSourcecode](https://lua-users.org/wiki/DumpingFunctionsSourcecode)) —
   fine here since `fhUtils.lua`'s methods are themselves Lua functions, but worth noting
   as a general limit of the technique.
2. **It doesn't matter here, because `fhUtils.lua` ships as plain interpretable source,
   not precompiled/stripped bytecode** (confirmed by issue #22's own investigation
   methodology — the audit read "`fhUtils.lua`'s actual source" directly, and `bridge/sandbox.lua`
   line 208 does `require('fhUtils')` against what is, per #22, a `.lua` text file on
   disk). Given the source text is already available and human/machine-readable, running
   it through `luac` to get bytecode and then disassembling the bytecode back into
   something resembling the original call structure is a **strictly lossy round-trip**
   compared to just parsing the source text or AST directly (§4) — bytecode disassembly
   would only earn its complexity if FH shipped `fhUtils` as opaque precompiled bytecode
   with source unavailable, which it does not.

**Confidence: high** on the opcode mechanics (direct 5.3-specific bytecode reference,
consistent with the manual's own incompatibilities section); **high** on "this doesn't
apply usefully here" being the right call, given #22's own audit already had source access.

---

## 4. Source-level static analysis (parsing, or scoped grep)

**This is the right-shaped tool for this specific problem**, and this repo already has a
working, shipped precedent for exactly this technique.

`server/src/authorFhPluginTool.ts` (the tool covered by
`docs/adr/0004-author-fh-plugin-text-only-flag-risky-calls.md`) already flags risky
function calls in Claude-generated Lua text via a word-boundary regex, not an AST parser:

```ts
const EXCLUDED_CALL_PATTERN = new RegExp(
  `\\b(${SANDBOX_EXCLUDED_FUNCTIONS.join("|")})\\b`,
  "g",
);
```

run per-line, prepending a `-- FLAGGED: ...` comment above any matching line. The
surrounding code comment explicitly documents the trade-off: *"Text match, not an
AST-based call-site check — can also match the name inside a string literal or a
pre-existing comment... That's an acceptable direction to err in: a false-positive flag
just adds one harmless extra review comment, whereas a false negative would silently hide
a real excluded call."* This is a direct, already-accepted precedent in this codebase for
favoring cheap-and-slightly-imprecise text scanning over a real parser, for a
structurally identical problem (does this Lua text call a named risky function).

**Reliability, two tiers:**

- **Scoped grep / regex** (`iup\.Popup\s*\(`, `\bfile\.write\s*\(`, `\bfile\.read\s*\(`)
  is trivial to write and matches the `author_fh_plugin` precedent exactly. It catches
  every *direct* call inside the target function's own text. It is fooled by (a) string
  literals/comments containing the name (false positive — safe direction, per the ADR's
  own reasoning), and (b) **indirection**: a local helper function `H` that itself calls
  `iup.Popup`, called by the target function only as `H(...)` — a grep scoped to the
  target function's own source lines won't see that `H` is risky unless it also scans
  `H`'s definition and recursively follows every local helper call, i.e., builds a call
  graph. Issue #22 gives a concrete real example of exactly this shape: `createUpdateFact`
  doesn't call `iup.Popup` itself, it calls `getParam(...)`, which calls `iup.Popup` —
  one level of indirection, exactly the case the ticket asks about. A same-function-only
  grep would have missed `createUpdateFact`'s risk entirely; #22's audit only caught it by
  a human reading `getParam`'s body too.
- **A real Lua parser** (producing an AST, e.g. via a Lua-grammar parser — LuaRocks has
  several pure-Lua parsers, and `luacheck` itself is built on one, see §5) fixes the
  string/comment false-positive problem and, combined with a same-module call graph pass
  (walk every local function's call sites, resolve calls to other same-file locals,
  transitively propagate "touches `iup`/`file`" flags), **can** catch one-level (and
  multi-level) indirection *within the same file* — which covers `fhUtils.lua`'s actual
  shape, since `getParam` and `createUpdateFact` are both defined in the same module.
  Indirection *across* files (a local helper defined in a second module `fhUtils`
  `require`s) would need the analysis to follow `require()` targets too — more scope, but
  the same technique, not a different one.

**Confidence: high.** This is standard, well-understood static-analysis territory (no
speculative claims), and directly demonstrated as buildable-and-already-built in this
exact codebase for the sibling problem.

---

## 5. Existing tools: does `luacheck` (or similar) already do this?

**Partially — its core mechanism is close, but its purpose and default behavior don't
match "detect and enumerate risky global calls with indirection."**

[luacheck](https://github.com/lunarmodules/luacheck) ("A tool for linting and static
analysis of Lua code") is built around exactly the primitive this ticket needs: detecting
global-variable *access* (not just assignment) against a configured allowlist
(`--read-globals`/`globals` in its config, implemented in
[`src/luacheck/stages/detect_globals.lua`](https://github.com/mpeterv/luacheck/blob/master/src/luacheck/stages/detect_globals.lua)).
In principle you could configure a luacheck ruleset where `iup`, `file`, and other
risky/excluded names are simply *not* in the allowed-globals list, then run luacheck over
`fhUtils.lua` and treat every "accessing undefined global 'iup'" warning as a hit — this
reuses a real, actively maintained tool rather than hand-rolling a parser, and supports
Lua 5.1/5.2/5.3/LuaJIT syntax natively (relevant given FH is confirmed 5.3, §1).

**What it doesn't give you out of the box**: luacheck's global-access detection is a
single-file, single-pass warning report (`line N: accessing undefined global 'iup'`) — it
does not, by default, attribute *which named function* a given global access sits inside,
and it does **not** perform interprocedural call-graph analysis to catch indirection
(§4's `getParam`/`createUpdateFact` case) — a warning on the line inside `getParam` is
just a flat warning against that line, not folded up into "therefore `createUpdateFact` is
risky too." Getting the per-method classification this ticket's design question actually
needs (a `{methodName: risky|safe}` table, with indirection resolved) would mean writing a
thin driver around luacheck's warnings (map warning line numbers back to the enclosing
top-level function) plus a bespoke call-graph pass for indirection — luacheck solves the
"detect a named global access" primitive, not the "produce a per-method safety
classification with transitive indirection resolved" deliverable directly.

**Confidence: medium-high** on luacheck's own capabilities (README + a source file
directly, both fetched); the "would need a driver on top" conclusion is my own reasoning
from those facts, not a directly-cited claim.

---

## 6. Verdict and reasoning

Answering the ticket's literal question first: **yes, it is technically feasible** to
detect that a Lua function references a specific named global like `iup.Popup` or
`file.write`, without calling that function — via source-level parsing (§4) is the
reliable, low-friction route; bytecode disassembly (§3) can do it too but adds a build
step (needs a live loaded function or `luac` over the source) for no accuracy gain over
just reading the source, since `fhUtils.lua` ships as plain source, not opaque bytecode;
the `debug` library alone (§2) cannot do it without either calling the function or going
one level deeper into bytecode/source anyway.

**Whether it's worth building as an automated capability is a separate question, and the
answer is no**, for four converging reasons:

1. **The problem doesn't recur often.** `fhUtils.lua` changes when FH ships a new major
   version (per the help corpus, this last happened at "Version 7" — an infrequent,
   human-noticed event, not something arriving on every release). A one-time hand-read
   audit (issue #22) already happened and is captured as a static list
   (`FHU_WRITE_METHOD_NAMES` in `bridge/sandbox.lua`). Re-running that audit the next time
   FH ships a `fhUtils` update is a bounded, occasional cost — not a per-commit or
   per-release recurring tax that would justify amortizing tooling-build cost against.
2. **The reliable version of automated detection (source-level parsing with a call-graph
   pass, §4) is not fundamentally different work from what a careful human audit already
   does** — reading the source, tracing which helper a public method calls, checking each
   helper's own body. Building a parser+call-graph tool to replace that is real
   engineering (Lua grammar parsing, `require()`-following module resolution, keeping a
   risky-name list in sync — this repo's own `SANDBOX_EXCLUDED_FUNCTIONS` in
   `authorFhPluginTool.ts` is *already* hand-duplicated from `bridge/sandbox.lua`, per
   that code's own comments, because the two run in different language runtimes) — for a
   payoff that only accrues the next time `fhUtils` actually changes.
3. **This codebase already chose the cheap, imprecise-in-a-safe-direction tool for the
   structurally identical problem** (§4's `authorFhPluginTool.ts` regex flagger,
   ADR 0004) — favoring "flag too much, human reviews" over building an AST-based
   call-site checker. The same reasoning applies here: a scoped grep (or, if indirection
   coverage matters enough, luacheck configured against a risky-globals list, §5) run by a
   human the next time `fhUtils.lua` changes, cross-checked by actually reading the
   flagged methods' bodies (as #22 already did), is proportionate. A **fully automated,
   self-re-classifying runtime capability** — the more ambitious version the ticket's
   background floats — adds a live-FH-process dependency (§3's obstacle 1) or a
   parser+call-graph maintenance burden (§4) for a classification that, per point 1,
   rarely needs re-running.
4. **The riskiest failure mode (a missed indirection, e.g. `createUpdateFact`→`getParam`→`iup.Popup`)
   is exactly the case a human audit already caught in #22**, and is also the case that
   naive tooling (plain grep, luacheck's flat per-line warnings) does **not** catch for
   free — so a "build automated tooling" path that stops at the easy 80% (direct calls)
   would be less trustworthy than the audit-plus-static-list this repo already has, unless
   it goes all the way to a real call-graph pass — which is where the cost/benefit tips
   most clearly toward "not worth it" for an infrequent classification task.

**Recommendation for the mechanism-decision ticket (#30)**: keep the one-time hand-read
audit as the mechanism, the same shape as #22. If the manual-audit burden ever grows
(e.g. FH starts shipping frequent `fhUtils` point releases, or a second/third FH-shipped
module needs the same treatment as floated in #28's "Out of scope" for `fhFileUtils`/`fhSql`),
revisit with a scoped grep first (cheapest, matches this repo's existing
`authorFhPluginTool.ts` precedent and risk-direction bias), reaching for luacheck
configured against a risky-globals list only if false negatives from plain grep turn out
to matter in practice, and reaching for a real parser+call-graph pass only if indirection
misses actually happen and get caught late.

---

## Sources

- FH's own shipped help, `server/data/fh-help-corpus.jsonl`: `/help/fh8plugins/New_in_Version_7.htm`,
  `/help/fh8plugins/lua/convert-5.1-5.3-lua.html`, `/help/fh8plugins/lua/additional-libraries.htm`
- [Lua 5.3 Reference Manual, §6.10 (Debug Library)](https://www.lua.org/manual/5.3/manual.html#6.10)
- [Lua 5.3 Reference Manual, §6.4 (String Manipulation) — `string.dump`](https://www.lua.org/manual/5.3/manual.html#6.4)
- [Lua 5.2 Reference Manual, §8.1 (Incompatibilities — the language)](https://www.lua.org/manual/5.2/manual.html#8.1)
- [Ravi Programming Language docs — Lua 5.3 Bytecode Reference](https://the-ravi-programming-language.readthedocs.io/en/latest/lua_bytecode_reference.html)
- [LuaJIT extensions page](https://luajit.org/extensions.html) (LuaJIT's own statement of Lua-5.1-based compatibility)
- [gammon.com.au Lua manual mirror](https://www.gammon.com.au/scripts/doc.php?lua=debug.getupvalue) (verbatim manual text for `debug.getupvalue`, `debug.getinfo`)
- [lua-users.org wiki — Dumping Functions Sourcecode](https://lua-users.org/wiki/DumpingFunctionsSourcecode)
- [luacheck (lunarmodules/luacheck) README](https://github.com/lunarmodules/luacheck)
- [luacheck `detect_globals.lua` source](https://github.com/mpeterv/luacheck/blob/master/src/luacheck/stages/detect_globals.lua)
- This repo: `bridge/sandbox.lua`, `bridge/watchdog.lua`, `CONTEXT.md` ("Sandbox"),
  `docs/adr/0001-arbitrary-sandboxed-lua-execution.md`,
  `docs/adr/0004-author-fh-plugin-text-only-flag-risky-calls.md`,
  `server/src/authorFhPluginTool.ts`,
  [issue #22](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/22),
  [issue #28](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/28)
