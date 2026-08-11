-- Standalone tests for runScript.lua. Run with: lua bridge/tests/runScript.test.lua
-- No FH/socket/iup dependency — exercises the full compile/execute/encode path a
-- run_lua request goes through, minus the socket framing (covered manually — see the
-- spec's Testing Decisions).

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../?.lua'
local runScript = require('runScript')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

-- Sandbox construction is now fallible (it requires fhUtils, an FH-shipped module not
-- resolvable on this plain-lua test process's package.path) — a build failure must
-- surface as a JSON error, not crash the caller, same as a compile/runtime error does.
local buildFailure = runScript.run('return 1')
check(contains(buildFailure, '"error"') and contains(buildFailure, 'fhUtils'),
  'a sandbox construction failure (e.g. missing fhUtils) surfaces as a JSON error, not a crash')

-- Stub fhUtils via package.loaded so require('fhUtils') inside sandbox.build() resolves
-- without a real FH install, the same mechanism it'll use for real inside FH. Needed as a
-- prerequisite for every assertion below, not something under test itself. createIndi is
-- included so the send-then-rethrow tests further down have a real write path to call
-- through fhu (sandbox.lua's write tracker, issue #15, only fires on an actual call).
package.loaded.fhUtils = {
  records = function(tag) end,
  createIndi = function(sName) return 'indi:' .. tostring(sName) end,
}

-- sourceHelper/sessionLogHelper (require('sourceHelper')/require('sessionLogHelper') inside
-- sandbox.build()) are this project's own modules, not FH-shipped -- resolvable for real via
-- package.path, but their real implementations call further real fh* globals this plain-lua
-- test process doesn't stub. Stub via package.loaded the same way fhUtils is stubbed above,
-- needed as a prerequisite for the write-then-log tests further down (issue #43), which
-- exercise fhBridge.logActivity as the one avenue to flip tracker.logged. validate* stubs
-- (issue #97) are always-succeeding no-ops, same "independent of the real module's own
-- behavior" reasoning as the mutate stubs beside them -- sandbox.lua's validatedTrackedWrite/
-- validatedTrackedLog now call these before the real mutate function, and the fixture scripts
-- below pass a plain 'ptr' string (not a real Item Pointer with :IsNull()), which the real
-- validateLogActivity/validateCiteSource would reject -- that rejection path is covered by
-- sourceHelper.test.lua/sessionLogHelper.test.lua instead, this file is only testing
-- runScript.lua's own pre-scan/rollback/backstop behavior.
package.loaded.sourceHelper = {
  validateCreateSourceFromTemplate = function() end,
  createSourceFromTemplate = function() end,
  validateCiteSource = function() end,
  citeSource = function() end,
}
package.loaded.sessionLogHelper = {
  validateLogActivity = function() end,
  logActivity = function(ptrRecord, action) return 'logged:' .. tostring(action) end,
}

check(runScript.run('return {ok=true}') == '{"ok":true}', 'trivial script returns encoded result')
check(runScript.run('return 42') == '42', 'script returning a bare number')
check(runScript.run('return nil') == 'null', 'script returning nil')
check(runScript.run('') == 'null', 'empty script (implicit nil return)')

local compileErr = runScript.run('this is not valid lua (')
check(contains(compileErr, '"error"') and contains(compileErr, 'failed to compile'), 'syntax error surfaces as a compile error')

local runtimeErr = runScript.run("error('boom')")
check(contains(runtimeErr, '"error"') and contains(runtimeErr, 'boom'), 'runtime error surfaces the error message')

local sandboxedAway = runScript.run("return os.execute('echo hi')")
check(contains(sandboxedAway, '"error"') and contains(sandboxedAway, 'nil value'),
  'calling a sandboxed-away function (os.execute) fails as calling nil, not silently succeeding')

local usesAllowed = runScript.run("return { doubled = 21 * 2, greeting = string.upper('hi') }")
check(contains(usesAllowed, '"doubled":42') and contains(usesAllowed, '"greeting":"HI"'),
  'script can use allowlisted math/string operations')

-- Integration-level watchdog check, using the real default INSTRUCTION_LIMIT (not
-- lowered, unlike watchdog.test.lua's own unit tests) — proves the wiring in runScript
-- itself, not just watchdog.lua in isolation. Bounded by this file's own wall-clock
-- check, plus the caller's process-level timeout as a hard backstop.
local watchdogStart = os.clock()
local runaway = runScript.run('while true do end')
local watchdogElapsed = os.clock() - watchdogStart
check(contains(runaway, '"error"') and contains(runaway, 'instruction limit'),
  'an infinite-loop script is aborted with a JSON error instead of hanging')
check(watchdogElapsed < 10, 'the watchdog aborts within a bounded wall-clock time')

-- A normal script run immediately after a watchdog abort must be unaffected — proves
-- the hook is cleared, not just that the aborted script itself terminated.
check(runScript.run('return 99') == '99', 'a normal script after a watchdog abort still runs correctly')

-- Access mode plumbing (issue #13): run() accepts and forwards an accessMode argument to
-- sandbox.build(). Read-write additionally grants the full write API (issue #14) — see
-- sandbox.test.lua for that allowlist's own present/absent assertions; here we only check
-- that both modes still behave identically for the basics every script can use.
check(runScript.run('return {ok=true}', 'read-write') == '{"ok":true}',
  'accessMode is accepted and forwarded without changing behavior (read-write)')
check(runScript.run('return {ok=true}', 'read-only') == '{"ok":true}',
  'accessMode is accepted and forwarded without changing behavior (explicit read-only)')
check(runScript.run("return os.execute('echo hi')", 'read-write'):find('"error"', 1, true) ~= nil,
  'a read-write run still cannot reach a permanently-excluded function (os.execute)')

-- Send-then-rethrow (issue #15, docs/adr/0005): a write-mode runtime error is still
-- reported to the caller as a normal JSON error response (the "send" half), but M.run's
-- second return value carries the original error so the caller can re-raise it after
-- sending -- giving FH's own auto-undo a chance to undo a partial write. This only
-- applies when the script actually wrote something before erroring (sandbox.lua's write
-- tracker) -- a write-mode script that errors without ever calling a write function has
-- nothing for FH's auto-undo to act on, so it behaves the same as read-only. Read-only
-- never has anything to undo at all, so it never returns a second value either way.
do
  -- Includes a logActivity mention/call so this passes the write-then-log pre-scan (issue
  -- #43) and reaches the runtime error the way it did before that enforcement existed --
  -- this test is about the send-then-rethrow mechanism, not the pre-scan itself.
  local response, rethrow = runScript.run("fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'write-mode runtime error after a tracked write still sends a normal JSON error response')
  check(contains(response, '"writeSessionRolledBack":true'),
    'write-mode runtime error after a tracked write carries the writeSessionRolledBack hint')
  check(rethrow ~= nil, 'write-mode runtime error after a tracked write returns a non-nil second value to re-raise')
end

do
  local response, rethrow = runScript.run("error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'write-mode runtime error with no prior write still sends a normal JSON error response')
  check(not contains(response, 'writeSessionRolledBack'),
    'write-mode runtime error with no prior write carries no writeSessionRolledBack hint (nothing was written)')
  check(rethrow == nil, 'write-mode runtime error with no prior write returns no second value (nothing to undo)')
end

do
  local response, rethrow = runScript.run("error('boom')", 'read-only')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'read-only runtime error still sends a normal JSON error response')
  check(not contains(response, 'writeSessionRolledBack'),
    'read-only runtime error response carries no writeSessionRolledBack hint')
  check(rethrow == nil, 'read-only runtime error returns no second value (nothing to undo)')
end

do
  local _, rethrow = runScript.run("error('boom')")
  check(rethrow == nil, 'a runtime error with no accessMode argument (defaults read-only) returns no second value')
end

-- A compile error or sandbox-build failure means the script never executed at all, so
-- there's nothing a write could have partially done -- these never rethrow even in
-- read-write, unlike a runtime error from a script that started running.
do
  local response, rethrow = runScript.run('this is not valid lua (', 'read-write')
  check(contains(response, 'failed to compile'), 'a compile error is still reported as such in write mode')
  check(rethrow == nil, 'a compile error never rethrows, even in write mode (the script never ran)')
end

-- Write-then-log enforcement (issue #43, docs/adr/0012): static pre-scan plus a runtime
-- backstop, so a script that writes without logging is rejected before it ever runs when
-- the sandbox can tell from the source alone, and via the ADR 0005 rethrow/auto-undo
-- mechanism when it can't.

-- Read-only script containing a write-name call: rejected before execution, clear
-- message, no rethrow value (same treatment as today's compile-error path).
do
  local response, rethrow = runScript.run("fhu.createIndi('X')", 'read-only')
  check(contains(response, '"error"') and contains(response, 'createIndi') and contains(response, 'Read-only'),
    'read-only script calling a write-capable function is rejected before execution with a clear message')
  check(rethrow == nil, 'a read-only pre-scan rejection returns no second value')
end

-- Read-write script containing a write-name call with no logActivity mention: rejected
-- before execution, clear message, no rethrow value.
do
  local response, rethrow = runScript.run("fhu.createIndi('X')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'createIndi') and contains(response, 'logActivity'),
    'read-write script calling a write-capable function with no logActivity mention is rejected before execution')
  check(not contains(response, 'writeSessionRolledBack'),
    'a pre-scan rejection carries no writeSessionRolledBack hint (nothing executed, nothing to roll back)')
  check(rethrow == nil, 'a pre-scan rejection returns no second value (nothing executed)')
end

-- Read-write script containing both a write-name call and a logActivity mention: the
-- pre-scan doesn't block a legitimate script, and it completes normally (real write
-- followed by a real logActivity call, so the runtime backstop passes too).
check(contains(
  runScript.run("fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); return {ok=true}", 'read-write'),
  '"ok":true'),
  'a read-write script that both writes and logs passes the pre-scan and runs normally')

-- Read-write script that calls a write function but logActivity's only appearance in the
-- source never actually executes (dead code): passes the pre-scan (the text is present),
-- but is caught by the post-run backstop.
do
  local response, rethrow = runScript.run(
    "fhu.createIndi('X'); if false then fhBridge.logActivity('ptr', 'never runs') end",
    'read-write')
  check(contains(response, '"error"') and contains(response, 'logActivity'),
    'a write with only dead-code logActivity passes the pre-scan but is caught by the runtime backstop')
  check(contains(response, '"writeSessionRolledBack":true'),
    'the runtime backstop response carries the writeSessionRolledBack hint')
  check(rethrow ~= nil, 'the runtime backstop returns a non-nil second value to re-raise')
end

-- Read-write script that calls only fhBridge.logActivity (no other write call): completes
-- normally, no backstop error -- proves tracker.wrote and tracker.logged both flip from
-- the same call and don't false-positive against each other.
check(contains(runScript.run("fhBridge.logActivity('ptr', 'reminder'); return {ok=true}", 'read-write'), '"ok":true'),
  'a script that only calls fhBridge.logActivity (no other write) completes normally with no backstop error')

-- Read-write script that batches several writes and a single logActivity call at the end:
-- passes, proving the backstop requires "logging happened," not "logging happened once
-- per write."
check(contains(runScript.run(
  "fhu.createIndi('A'); fhu.createIndi('B'); fhu.createIndi('C'); fhBridge.logActivity('ptr', 'created A, B, C'); return {ok=true}",
  'read-write'), '"ok":true'),
  'a script that batches several writes with a single trailing logActivity call completes normally')

-- Unrecognized-fh*-global pre-scan (issue #81, docs/adr/0022): rejects a script calling a
-- bare fh* global this sandbox doesn't recognize, before it ever runs -- the real incident
-- was fhGetQualifiedId (guessed), a typo for fhGetQualifiedRecordId (the real, allowlisted
-- name).
do
  local response, rethrow = runScript.run("return fhGetQualifiedId(newest)", 'read-only')
  check(contains(response, '"error"') and contains(response, 'unrecognized') and contains(response, 'fhGetQualifiedId'),
    'a script calling a genuine typo\'d/unknown fh* name is rejected before execution with a clear message')
  check(rethrow == nil, 'an unrecognized-fh*-call rejection returns no second value (nothing executed)')
end

-- A known-but-permanently-excluded name (sandbox.EXCLUDED_FH_GLOBAL_REASONS) gets the
-- specific reason, not the generic "unrecognized" message -- distinguishes a typo from a
-- deliberate exclusion.
do
  local response = runScript.run("return fhShellExecute('calc.exe')", 'read-only')
  check(contains(response, '"error"') and contains(response, 'fhShellExecute') and contains(response, 'not supported over run_lua'),
    'a script calling a known-but-excluded fh* name gets the specific exclusion reason')
  check(not contains(response, 'unrecognized'),
    'a known-but-excluded name is not also reported as unrecognized')
end

-- A script calling only known-good bare fh* names is unaffected by the new check. This
-- plain-lua test process doesn't stub every individual fh* global the way sandbox.test.lua
-- does (out of scope for a runScript-level test), so fhBeginsWithVowel resolves to nil here
-- and the call still fails -- but as an ordinary "attempt to call a nil value" runtime
-- error, exactly like the existing os.execute ("sandboxed-away") check above, proving the
-- pre-scan itself let it through rather than rejecting it as unrecognized.
do
  local response = runScript.run("return fhBeginsWithVowel('Anne')")
  check(not contains(response, 'unrecognized'),
    'a script calling only a known-good fh* name is not rejected by the pre-scan')
  check(contains(response, 'nil value'),
    'the known-good name reaches execution and fails only because this plain-lua test process has no real fhBeginsWithVowel global stubbed')
end

-- A name appearing only inside a comment/string doesn't false-positive -- documenting the
-- pre-scan's known text-heuristic limitation (same limitation preScanViolation already has,
-- issue #43): it looks for an identifier-boundary match immediately followed by '(', so a
-- bare mention with no call paren (e.g. inside a string, with no trailing parenthesis) is
-- not flagged. A name followed by '(' *inside* a string literal WOULD still false-positive,
-- same as preScanViolation -- not exercised here since it isn't this check's job to be a
-- real parser, just to fast-fail the common case.
check(not contains(runScript.run("return 'mentions fhGetQualifiedId but never calls it'"), '"error"'),
  'a fh*-prefixed name with no trailing call paren (e.g. mentioned in a string) does not false-positive')

-- Report-both (2026-08-08 grilling session follow-up): a script tripping both the
-- write-violation pre-scan and the unrecognized-fh*-call pre-scan in the same run gets both
-- messages, concatenated into the single existing `error` string -- not just the first hit.
do
  local response = runScript.run("fhu.createIndi('X'); return fhGetQualifiedId(newest)", 'read-only')
  check(contains(response, '"error"') and contains(response, 'createIndi') and contains(response, 'Read-only')
    and contains(response, 'unrecognized') and contains(response, 'fhGetQualifiedId'),
    'a script tripping both pre-scans in the same run reports both violations, not just the first')
end

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
