-- Standalone tests for runScript.lua. Run with: lua bridge/tests/runScript.test.lua
-- No FH/socket/iup dependency — exercises the full compile/execute/encode path a
-- run_lua request goes through, minus the socket framing (covered manually — see the
-- spec's Testing Decisions).

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
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

-- Commit/rollback stubs (issue #133): bare identifiers, the same ones runScript.lua calls
-- for real inside FH. Permitted as bare identifiers in test code per
-- docs/INTERNAL-commit-rollback-plan.md's naming rule -- never named in comment prose,
-- including this one (see this file's own assertions below for what each stub is used to
-- prove). Call counts and throw-forcing are reset before each test that cares about them; a
-- test that doesn't reset them is asserting against whatever the previous test left behind,
-- so every fixture below resets first.
local fhCommitCalls = 0
local fhRollbackCalls = 0
local forceCommitThrow = false
local forceRollbackThrow = false

local function resetCommitRollbackStubs()
  fhCommitCalls = 0
  fhRollbackCalls = 0
  forceCommitThrow = false
  forceRollbackThrow = false
end

fhCommit = function()
  fhCommitCalls = fhCommitCalls + 1
  if forceCommitThrow then
    error('commit stub forced failure')
  end
  return fhCommitCalls
end

fhRollback = function()
  fhRollbackCalls = fhRollbackCalls + 1
  if forceRollbackThrow then
    error('rollback stub forced failure')
  end
end

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

-- Rollback-first, rethrow-as-fallback (issue #133, supersedes issue #15/docs/adr/0005 as
-- the primary path): a write-mode runtime error after a tracked write attempts a rollback
-- of everything written so far. When that succeeds, the Session survives -- a normal JSON
-- error response, no writeSessionRolledBack hint, no rethrow (the caller just resubmits).
-- ADR 0005's send-then-rethrow mechanism becomes a fallback of last resort, exercised only
-- when the rollback attempt itself throws (covered further down). A write-mode script that
-- errors without ever calling a write function has nothing to roll back, so it behaves the
-- same as read-only. Read-only never has anything to undo at all, so it never returns a
-- non-nil transaction result either way.
do
  resetCommitRollbackStubs()
  -- Includes a logActivity mention/call so this passes the write-then-log pre-scan (issue
  -- #43) and reaches the runtime error the way it did before that enforcement existed --
  -- this test is about the rollback-first mechanism, not the pre-scan itself.
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'write-mode runtime error after a tracked write still sends a normal JSON error response')
  check(not contains(response, 'writeSessionRolledBack'),
    'a successful rollback carries no writeSessionRolledBack hint -- the Session survives, nothing for FH\'s own auto-undo to do')
  check(rethrow == nil, 'a successful rollback returns no second value -- nothing to re-raise, the plugin stays alive')
  check(transactionResult == 'rolledback', 'a successful rollback reports "rolledback" as the third return value')
  check(fhRollbackCalls == 1, 'the rollback primitive is called exactly once')
  check(fhCommitCalls == 0, 'the rollback path never calls the commit primitive -- rollback alone undoes record creation on FH 8.0.0.12+')
end

-- Rollback-throws fallback (issue #133): when the rollback attempt itself throws, tree
-- state can't be trusted any more, so this falls back to ADR 0005's original
-- send-then-rethrow behavior -- ending the whole plugin so FH's own auto-undo can act.
do
  resetCommitRollbackStubs()
  forceRollbackThrow = true
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'a failed rollback attempt still sends a normal JSON error response')
  check(contains(response, '"writeSessionRolledBack":true'),
    'a failed rollback attempt falls back to the writeSessionRolledBack hint (ADR 0005)')
  check(rethrow ~= nil, 'a failed rollback attempt returns a non-nil second value to re-raise, ending the plugin')
  check(transactionResult == nil, 'the ADR-0005 fallback reports no transaction result (the rethrow path is what matters)')
  check(fhRollbackCalls == 1, 'the rollback primitive was attempted exactly once before falling back')
end

do
  resetCommitRollbackStubs()
  local response, rethrow, transactionResult = runScript.run("error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'write-mode runtime error with no prior write still sends a normal JSON error response')
  check(not contains(response, 'writeSessionRolledBack'),
    'write-mode runtime error with no prior write carries no writeSessionRolledBack hint (nothing was written)')
  check(rethrow == nil, 'write-mode runtime error with no prior write returns no second value (nothing to undo)')
  check(transactionResult == nil, 'write-mode runtime error with no prior write reports no transaction result')
  check(fhRollbackCalls == 0, 'the rollback primitive is never called when nothing was written')
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
  resetCommitRollbackStubs()
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); if false then fhBridge.logActivity('ptr', 'never runs') end",
    'read-write')
  check(contains(response, '"error"') and contains(response, 'logActivity'),
    'a write with only dead-code logActivity passes the pre-scan but is caught by the runtime backstop')
  check(not contains(response, 'writeSessionRolledBack'),
    'the runtime backstop attempts a rollback first -- a successful one carries no writeSessionRolledBack hint')
  check(rethrow == nil, 'a successful rollback from the runtime backstop returns no second value -- the plugin stays alive')
  check(transactionResult == 'rolledback', 'the runtime backstop reports "rolledback" on a successful rollback')
  check(fhRollbackCalls == 1, 'the runtime backstop attempts the rollback primitive exactly once')
end

-- Read-write script that calls only fhBridge.logActivity (no other write call): completes
-- normally, no backstop error -- proves tracker.wrote and tracker.logged both flip from
-- the same call and don't false-positive against each other.
resetCommitRollbackStubs()
check(contains(runScript.run("fhBridge.logActivity('ptr', 'reminder'); return {ok=true}", 'read-write'), '"ok":true'),
  'a script that only calls fhBridge.logActivity (no other write) completes normally with no backstop error')

-- Read-write script that batches several writes and a single logActivity call at the end:
-- passes, proving the backstop requires "logging happened," not "logging happened once
-- per write."
check(contains(runScript.run(
  "fhu.createIndi('A'); fhu.createIndi('B'); fhu.createIndi('C'); fhBridge.logActivity('ptr', 'created A, B, C'); return {ok=true}",
  'read-write'), '"ok":true'),
  'a script that batches several writes with a single trailing logActivity call completes normally')

-- Commit-on-success (issue #133): a successful write-mode call with a tracked write
-- commits exactly once, after the script runs, and reports "committed" as the third
-- return value.
do
  resetCommitRollbackStubs()
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); return {ok=true}", 'read-write')
  check(contains(response, '"ok":true'), 'a successful write-mode call still returns the script\'s own result')
  check(fhCommitCalls == 1, 'a successful write-mode call with a tracked write commits exactly once')
  check(rethrow == nil, 'a successful commit returns no second value')
  check(transactionResult == 'committed', 'a successful write-mode call reports "committed" as the third return value')
end

-- Encode failure after a successful commit (issue #133): the write already committed by
-- the time the script's own return value turns out to be unencodable, so the caller still
-- needs to know via transactionResult, even though the response itself reports an error.
do
  resetCommitRollbackStubs()
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); return math.floor", 'read-write')
  check(contains(response, '"error"') and contains(response, 'failed to encode result'),
    'a script returning an unencodable value after a successful write reports an encode error')
  check(fhCommitCalls == 1, 'the commit still happens before the encode failure is discovered')
  check(rethrow == nil, 'an encode failure after a successful commit is not a rethrow case')
  check(transactionResult == 'committed',
    'the caller still learns the write was committed, even though the response itself is an error')
end

-- No commit when nothing was written (issue #133): a successful call that never triggers
-- the write tracker (read-only, or a read-write call that only reads) never calls commit.
do
  resetCommitRollbackStubs()
  local response, _, transactionResult = runScript.run('return {ok=true}', 'read-write')
  check(contains(response, '"ok":true'), 'a read-write call with nothing written still returns the script\'s own result')
  check(fhCommitCalls == 0, 'commit is never called when the write tracker never fired')
  check(transactionResult == nil, 'a call with nothing written reports no transaction result')
end

-- Commit-throws fallback (issue #133): symmetric with the rollback-throws case above -- if
-- the commit primitive itself throws after a successful script run, tree state can't be
-- trusted any more, so this falls back to ADR 0005's plugin-ending path too.
do
  resetCommitRollbackStubs()
  forceCommitThrow = true
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); return {ok=true}", 'read-write')
  check(contains(response, '"error"'), 'a failed commit attempt reports a JSON error, not the script\'s own result')
  check(contains(response, '"writeSessionRolledBack":true'),
    'a failed commit attempt falls back to the writeSessionRolledBack hint (ADR 0005)')
  check(rethrow ~= nil, 'a failed commit attempt returns a non-nil second value to re-raise, ending the plugin')
  check(transactionResult == nil, 'the ADR-0005 fallback reports no transaction result')
end

-- Watchdog abort after a tracked write (issue #133): a runaway script is still a runtime
-- error via pcall, so it goes through the same rollback-first path as any other write-mode
-- runtime error, not a separate mechanism.
do
  resetCommitRollbackStubs()
  local response, rethrow, transactionResult = runScript.run(
    "fhu.createIndi('X'); fhBridge.logActivity('ptr', 'created X'); while true do end", 'read-write')
  check(contains(response, '"error"') and contains(response, 'instruction limit'),
    'a watchdog abort after a tracked write still reports the instruction-limit error')
  check(not contains(response, 'writeSessionRolledBack'),
    'a watchdog abort after a tracked write attempts a rollback first, same as any other runtime error')
  check(rethrow == nil, 'a successful rollback after a watchdog abort returns no second value -- the plugin stays alive')
  check(transactionResult == 'rolledback', 'a watchdog abort after a tracked write reports "rolledback" on a successful rollback')
end

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

-- Bare-leading-dot Data Reference pre-scan (issue #103, docs/adr/0023): rejects a script
-- passing a literal Data Reference string starting with a bare '.' (neither the '~'-relative
-- form nor a full record-level-tag path) to any of the four call shapes that accept one --
-- MoveTo doesn't error on this, it silently leaves the pointer Null (same for
-- fhGetItemPtr); fhGetItemText/fhGetDisplayText silently return "" instead. The real
-- incident: child:MoveTo(otherPtr, '.DATE') (missing the leading '~') never errored, just
-- left datePtr Null forever, so the loop that checked datePtr:IsNotNull() never matched.
do
  local response, rethrow = runScript.run("child:MoveTo(otherPtr, '.DATE')", 'read-only')
  check(contains(response, '"error"') and contains(response, 'MoveTo') and contains(response, 'leading dot'),
    'a literal bare-leading-dot MoveTo data reference is rejected before execution')
  check(rethrow == nil, 'a bare-leading-dot pre-scan rejection returns no second value (nothing executed)')
end

check(contains(runScript.run("return fhGetItemText(ptr, '.DATE')"), 'leading dot'),
  'fhGetItemText with a literal bare-leading-dot data reference is rejected')
check(contains(runScript.run("return fhGetDisplayText(ptr, '.BIRT')"), 'leading dot'),
  'fhGetDisplayText with a literal bare-leading-dot data reference is rejected')
check(contains(runScript.run("return fhGetItemPtr(ptr, '.TEXT')"), 'leading dot'),
  'fhGetItemPtr with a literal bare-leading-dot data reference is rejected')

-- A '~'-relative reference (the correct form) never trips the check -- reaches execution
-- and fails only because this plain-lua test process has no real MoveTo/fhNewItemPtr
-- stubbed, same "reaches execution" proof style as the known-good-fh*-name test above.
check(not contains(runScript.run("child:MoveTo(otherPtr, '~.DATE')"), 'leading dot'),
  'a correct ~-relative MoveTo data reference does not trip the leading-dot check')

-- A full record-level-tag path (no '~', no leading dot) is the other valid form and must
-- not trip the check either.
check(not contains(runScript.run("return fhGetItemText(ptr, 'INDI.BIRT.DATE')"), 'leading dot'),
  'a full record-level-tag path data reference does not trip the leading-dot check')

-- MoveToFirstChildItem/MoveToFirstRecord/etc. share the "MoveTo" prefix but are entirely
-- different methods with no Data Reference argument at all -- the pattern requires "MoveTo"
-- immediately followed by "(", so these never match.
check(not contains(runScript.run("child:MoveToFirstChildItem(parentPtr, '.FLGS')"), 'leading dot'),
  'MoveToFirstChildItem is not mistaken for MoveTo by the leading-dot check')

-- Known text-heuristic limitation, same as every other pre-scan here: a data reference
-- built into a variable first, rather than passed as a literal, isn't caught.
check(not contains(runScript.run("local ref = '.DATE'; child:MoveTo(otherPtr, ref)"), 'leading dot'),
  'a bare-leading-dot data reference built into a variable first does not false-positive (known limitation)')

-- Report-both: a script tripping both the leading-dot check and the unrecognized-fh*-call
-- pre-scan in the same run gets both messages, same "report everything at once" policy as
-- every other pre-scan pairing.
do
  local response = runScript.run("fhGetItemText(ptr, '.DATE'); return fhGetQualifiedId(newest)", 'read-only')
  check(contains(response, 'leading dot') and contains(response, 'unrecognized') and contains(response, 'fhGetQualifiedId'),
    'a script tripping both the leading-dot check and the unrecognized-fh*-call pre-scan reports both violations')
end

-- privacySettings forwarding (issue #141): M.run passes its third argument through to
-- sandbox.build, which calls the real familyHelper.setPrivacySettings -- checked via
-- familyHelper's own getPrivacySettings accessor since privacySettings isn't part of a
-- run_lua script's own return value. familyHelper.lua is a real project module (not
-- FH-shipped), so it's resolvable via package.path without any stub.
do
  local familyHelper = require('familyHelper')
  runScript.run('return 1', 'read-only', { privateVisibility = 'exclude', livingVisibility = 'nameOnly' })
  local settings = familyHelper.getPrivacySettings()
  check(settings.privateVisibility == 'exclude' and settings.livingVisibility == 'nameOnly',
    'M.run forwards its privacySettings argument through sandbox.build to familyHelper.setPrivacySettings')

  runScript.run('return 1', 'read-only')
  local defaulted = familyHelper.getPrivacySettings()
  check(defaulted.privateVisibility == 'all' and defaulted.livingVisibility == 'all',
    'M.run with no privacySettings argument defaults to unfiltered "all"/"all"')
end

-- Bulk-enumeration pre-scan (issue #141): raw MoveToFirstRecord bypasses every fhBridge.*
-- helper's Visibility filtering, so it's rejected while any Visibility level is restricted.
do
  local restricted = { privateVisibility = 'exclude', livingVisibility = 'all' }
  local response = runScript.run("ptr:MoveToFirstRecord('INDI')", 'read-only', restricted)
  check(contains(response, '"error"') and contains(response, 'MoveToFirstRecord') and contains(response, 'bypasses'),
    'MoveToFirstRecord is rejected while privateVisibility is restricted')
  check(contains(response, 'exclude') and contains(response, 'all'),
    'the rejection names both Visibility levels actually in effect')
end

do
  local restricted = { privateVisibility = 'all', livingVisibility = 'nameOnly' }
  local response = runScript.run("ptr:MoveToFirstRecord('FAM')", 'read-only', restricted)
  check(contains(response, 'MoveToFirstRecord'),
    'MoveToFirstRecord is rejected while livingVisibility alone is restricted, regardless of which record tag is enumerated')
end

-- "not rejected" is checked via absence of the violation's own wording, not absence of
-- '"error"' generally -- ptr is an undefined global in this fixture script, so it still
-- fails at execution with an unrelated "attempt to index a nil value" error either way.
check(not contains(runScript.run("ptr:MoveToFirstRecord('INDI')", 'read-only'), 'bypasses'),
  'MoveToFirstRecord is not rejected by the pre-scan when no privacySettings argument is passed (defaults to unfiltered "all"/"all")')

check(not contains(runScript.run("ptr:MoveToFirstRecord('INDI')", 'read-only', { privateVisibility = 'all', livingVisibility = 'all' }), 'bypasses'),
  'MoveToFirstRecord is not rejected by the pre-scan when both Visibility levels are explicitly "all"')

check(not contains(runScript.run("return fhBeginsWithVowel('Anne')", 'read-only', { privateVisibility = 'exclude', livingVisibility = 'all' }), 'MoveToFirstRecord'),
  'a script that never mentions MoveToFirstRecord is unaffected by a restricted Visibility level')

-- fhu.records/allItems/indiList are the RUN_LUA_DESCRIPTION-recommended idioms for iterating
-- records -- all three just wrap MoveToFirstRecord/MoveNext internally, so each is rejected
-- the same as a hand-rolled MoveToFirstRecord loop, not waved through as the "safe" choice.
for _, call in ipairs({ 'fhu.records', 'fhu.allItems', 'fhu.indiList' }) do
  local restricted = { privateVisibility = 'exclude', livingVisibility = 'all' }
  local response = runScript.run("for p in " .. call .. "('INDI') do end", 'read-only', restricted)
  check(contains(response, call) and contains(response, 'bypasses'),
    call .. ' is rejected while privateVisibility is restricted, same as a raw MoveToFirstRecord loop')
end

check(not contains(runScript.run("local records = {}; return records", 'read-only', { privateVisibility = 'exclude', livingVisibility = 'all' }), 'bypasses'),
  'a bare local variable named records is not mistaken for the fhu.records idiom (word-boundary match requires the fhu. prefix)')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
