-- Executes a run_lua script inside the sandbox and returns a JSON-encoded response string
-- -- either the script's own returned value, or a JSON error object on failure. Ties
-- sandbox.lua and jsonEncode.lua together; no socket/IUP/FH dependency of its own, so
-- (unlike bridge.fh_lua's dialog/socket plumbing) this is testable standalone.
--
-- accessMode defaults to "read-only" (mirroring sandbox.build()'s own default) -- M.run
-- needs a resolved value for the pre-scan below before sandbox.build ever runs.
--
-- M.run returns up to three values: (response, rethrowErr, transactionResult).
-- rethrowErr is non-nil only in the ADR-0005 fallback-of-last-resort case (see
-- rollbackResponse below) -- bridgeSession.lua re-raises it to end the whole plugin.
-- transactionResult is "committed" for a successful write-mode call, "rolledback" for a
-- write-mode failure that was undone without ending the plugin, or nil (read-only calls,
-- a write-mode call that never wrote anything, or the rethrow case above) -- see
-- docs/INTERNAL-commit-rollback-plan.md (issue #133) for the full design.

local sandbox = require('sandbox')
local json = require('jsonEncode')
local watchdog = require('watchdog')

local M = {}

-- Word-boundary match, not naive substring search: 'createIndi' must not match inside a
-- longer identifier like 'createIndiOld'. Lua's %f frontier pattern treats %w_ as "word"
-- characters and anything else (including string start/end) as a boundary, which is
-- exactly the identifier-boundary semantics an unquoted Lua call site has.
local function containsName(scriptText, name)
  return scriptText:find('%f[%w_]' .. name .. '%f[^%w_]') ~= nil
end

-- Set form of sandbox.KNOWN_FH_GLOBAL_NAMES, built once at module load for O(1) membership
-- checks in unrecognizedFhCallViolation below.
local knownFhGlobalNames = {}
for _, name in ipairs(sandbox.KNOWN_FH_GLOBAL_NAMES) do
  knownFhGlobalNames[name] = true
end

-- Static pre-scan: a best-effort heuristic over the script's raw source text, not a
-- security boundary -- the runtime backstop in M.run below is what actually guarantees no
-- write escapes detection. Runs before load() is even attempted, so it catches a violation
-- even in a script that wouldn't otherwise compile.
local function preScanViolation(scriptText, accessMode)
  local writeName = nil
  for _, name in ipairs(sandbox.WRITE_NAMES) do
    if containsName(scriptText, name) then
      writeName = name
      break
    end
  end
  if not writeName then
    return nil
  end

  if accessMode == 'read-only' then
    return 'script calls ' .. writeName .. ', a write-capable function, but the bridge is in Read-only mode'
  end

  if accessMode == 'read-write' and not containsName(scriptText, 'logActivity') then
    return 'script calls ' .. writeName .. ', a write-capable function, but never calls fhBridge.logActivity to log the write'
  end

  return nil
end

-- Extracts every bare fh*-prefixed identifier immediately followed by a call paren -- e.g.
-- matches 'fhGetQualifiedId' in 'fhGetQualifiedId(newest)'. A dot immediately after the
-- identifier breaks the match ('fhu.foo(', 'fhBridge.getFamilyGroup(' never match) --
-- scoped to bare fh* globals only, not fhu.* methods or item-pointer :Method() calls (a
-- text pre-scan can't validate a method call without knowing the calling object's type).
local function eachFhCallName(scriptText)
  return scriptText:gmatch('%f[%w_](fh%w*)%f[^%w_]%s*%(')
end

-- Unrecognized-fh*-global pre-scan: rejects a run_lua script that calls a bare fh* global
-- this sandbox doesn't recognize -- either a genuine typo/hallucination, or a
-- known-but-permanently-excluded name (sandbox.EXCLUDED_FH_GLOBAL_REASONS) -- before
-- load() is even attempted, avoiding the partial-write-then-rollback cost of only finding
-- out at runtime. A best-effort text heuristic, same known limitations as preScanViolation
-- (a name inside a comment/string, or reached via indirection, isn't caught).
local function unrecognizedFhCallViolation(scriptText)
  local messages = {}
  local seen = {}
  for name in eachFhCallName(scriptText) do
    if not seen[name] then
      seen[name] = true
      local excludedReason = sandbox.EXCLUDED_FH_GLOBAL_REASONS[name]
      if excludedReason then
        table.insert(messages, 'script calls ' .. name .. ', which is not supported over run_lua: ' .. excludedReason)
      elseif not knownFhGlobalNames[name] then
        table.insert(messages, 'script calls an unrecognized function ' .. name)
      end
    end
  end
  if #messages == 0 then
    return nil
  end
  return table.concat(messages, '; ')
end

-- Bare-leading-dot Data Reference pre-scan: rejects a script passing a literal Data
-- Reference string starting with a bare '.' -- neither of the two valid forms (a
-- '~'-relative reference, or a full path from a record-level tag) -- to any of the four
-- call shapes FH's API accepts one on. None of the four raise a Lua error for this:
-- MoveTo/fhGetItemPtr silently leave the pointer Null, fhGetItemText/fhGetDisplayText
-- silently return "" -- indistinguishable from a genuinely absent field. Same
-- "literal argument only" heuristic limitation as every other pre-scan here.
local DATA_REF_CALL_SHAPES = {
  { name = 'MoveTo', symptom = 'silently leaves the pointer Null' },
  { name = 'fhGetItemPtr', symptom = 'silently leaves the pointer Null' },
  { name = 'fhGetItemText', symptom = 'silently returns an empty string' },
  { name = 'fhGetDisplayText', symptom = 'silently returns an empty string' },
}

local function dataReferenceViolation(scriptText)
  local messages = {}
  for _, shape in ipairs(DATA_REF_CALL_SHAPES) do
    -- '.-' (non-greedy) matches the 1st argument up to the first comma, so this doesn't
    -- see through an expression containing its own comma as the 1st argument -- same class
    -- of limitation eachFhCallName above already has. The %1 backreference requires the
    -- captured quote character to match at both ends.
    local pattern = '%f[%w_]' .. shape.name .. '%s*%(.-,%s*([\'"])(%.[^\'"]*)%1'
    local _, ref = scriptText:match(pattern)
    if ref then
      table.insert(messages, "script calls " .. shape.name .. "(..., '" .. ref ..
        "') with a Data Reference starting with a bare leading dot -- neither a '~'-relative " ..
        "reference nor a full record-level-tag path -- " .. shape.name .. " " .. shape.symptom ..
        " instead of erroring; use '~" .. ref .. "' if it's relative to the pointer passed, or " ..
        "a full path starting from a record-level tag (e.g. 'INDI" .. ref .. "')")
    end
  end
  if #messages == 0 then
    return nil
  end
  return table.concat(messages, '; ')
end

-- Bulk-enumeration pre-scan (issue #141): a script that calls MoveToFirstRecord walks the
-- raw GEDCOM tree directly, bypassing every fhBridge.* helper's Visibility filtering -- the
-- one gap this issue's own trust boundary leaves open (raw fh* calls stay unfiltered by
-- design). Only fires while a Visibility level is actually restricting something -- both
-- "all" means there's nothing to bypass, so a script run with no privacy settings active
-- never sees this message. Same word-boundary heuristic as preScanViolation: doesn't try to
-- tell which record tag is being enumerated (a FAM walk can still reach Individual data via
-- its members, so MoveToFirstRecord("FAM") is flagged the same as MoveToFirstRecord("INDI")).
-- Also catches fhu.records/fhu.allItems/fhu.indiList -- RUN_LUA_DESCRIPTION and the
-- gedcom-knowledge corpus both steer Claude to prefer these over a hand-rolled
-- MoveToFirstRecord/MoveNext loop, but all three just wrap the same unfiltered walk, so
-- leaving them out would block the discouraged idiom while waving the recommended one
-- straight through.
local ENUMERATION_NAMES = { 'MoveToFirstRecord', 'fhu%.records', 'fhu%.allItems', 'fhu%.indiList' }
local function bulkEnumerationViolation(scriptText, privacySettings)
  if privacySettings.privateVisibility == 'all' and privacySettings.livingVisibility == 'all' then
    return nil
  end
  local triggerName
  for _, name in ipairs(ENUMERATION_NAMES) do
    if containsName(scriptText, name) then
      triggerName = name:gsub('%%', '')
      break
    end
  end
  if not triggerName then
    return nil
  end
  return 'script calls ' .. triggerName .. ', which enumerates the raw GEDCOM tree and bypasses ' ..
    'this Session\'s Visibility settings (Private: ' .. tostring(privacySettings.privateVisibility) ..
    ', Living: ' .. tostring(privacySettings.livingVisibility) .. ') -- use fhBridge.findByNames/' ..
    'getFamilyGroup/getAncestors/getDescendants/getAllDetails/getFactsByTag instead, which apply ' ..
    'these settings automatically'
end

-- Shared shape for a write-mode response that ends the whole plugin so FH's own auto-undo
-- can act on the tree (ADR 0005): a JSON error carrying writeSessionRolledBack: true, plus
-- the original error/message as a second return value the caller re-raises after sending.
-- Fallback of last resort only (issue #133) -- used when the tree's own rollback/commit
-- primitive itself throws, at which point tree state can't be trusted and ending the
-- plugin is the safest available behavior. The ordinary case (that primitive succeeding)
-- never reaches this -- see attemptRollback below.
local function rollbackResponse(message)
  return json.encode({ error = tostring(message), writeSessionRolledBack = true }), message
end

-- Attempts a rollback of everything this call has written so far. Requires FH 8.0.0.12+,
-- where the rollback primitive alone undoes record creation as well as value edits. On
-- success the Session survives: an ordinary JSON error, no rethrow, no writeSessionRolledBack
-- -- the caller resubmits without FH's own "Plugin Error" pop-up ever firing. On failure (the
-- call throws), tree state can't be trusted any more, so this falls back to rollbackResponse's
-- plugin-ending path (ADR 0005) as a last resort.
local function attemptRollback(message)
  if pcall(fhRollback) then
    return json.encode({ error = tostring(message) }), nil, 'rolledback'
  end
  return rollbackResponse(message)
end

-- privacySettings ({privateVisibility=, livingVisibility=}, issue #141) defaults to
-- unfiltered "all"/"all", mirroring accessMode's own default-to-read-only above -- so a
-- caller that never passes one (any pre-#141 test, or a session with no restriction)
-- behaves exactly as before.
function M.run(scriptText, accessMode, privacySettings)
  accessMode = accessMode or 'read-only'
  privacySettings = privacySettings or { privateVisibility = 'all', livingVisibility = 'all' }

  -- All three pre-scans below run unconditionally and their messages are joined rather than
  -- short-circuiting after the first hit -- a script tripping more than one should hear
  -- about everything wrong with it in one round-trip, not fix one violation only to hit the
  -- next on resubmission.
  local violations = {}
  local writeViolation = preScanViolation(scriptText, accessMode)
  if writeViolation then
    table.insert(violations, writeViolation)
  end
  local fhCallViolation = unrecognizedFhCallViolation(scriptText)
  if fhCallViolation then
    table.insert(violations, fhCallViolation)
  end
  local dataRefViolation = dataReferenceViolation(scriptText)
  if dataRefViolation then
    table.insert(violations, dataRefViolation)
  end
  local bulkViolation = bulkEnumerationViolation(scriptText, privacySettings)
  if bulkViolation then
    table.insert(violations, bulkViolation)
  end
  if #violations > 0 then
    return json.encode({ error = table.concat(violations, '; ') })
  end

  local envOk, env, tracker = pcall(sandbox.build, accessMode, privacySettings)
  if not envOk then
    return json.encode({ error = 'failed to build sandbox: ' .. tostring(env) })
  end

  local chunk, loadErr = load(scriptText, 'run_lua', 't', env)
  if not chunk then
    return json.encode({ error = 'script failed to compile: ' .. tostring(loadErr) })
  end

  watchdog.start()
  local ok, result = pcall(chunk)
  watchdog.stop()

  if ok and accessMode == 'read-write' and tracker.wrote and not tracker.logged then
    -- Runtime backstop: the ground truth for what the pre-scan can't see -- text presence
    -- isn't proof of execution (dead code, indirection, partial logging). Same
    -- attempt-rollback-first handling as the write-mode-runtime-error path below.
    return attemptRollback('script wrote to the tree without logging the activity via fhBridge.logActivity')
  end

  if not ok then
    -- Only a write-mode script that actually called a tracked write primitive before
    -- erroring can have partially mutated the tree.
    if accessMode == 'read-write' and tracker.wrote then
      return attemptRollback(result)
    end
    return json.encode({ error = tostring(result) })
  end

  local committed = false
  if accessMode == 'read-write' and tracker.wrote then
    -- Success path: commit what this call wrote, once, before encoding the response. If
    -- the commit call itself throws, tree state can't be trusted any more -- same
    -- last-resort fallback as a failed rollback attempt below.
    local commitOk = pcall(fhCommit)
    if not commitOk then
      return rollbackResponse('script completed but the tree could not be committed')
    end
    committed = true
  end

  local encodeOk, encoded = pcall(json.encode, result)
  if not encodeOk then
    -- The write already committed above, if there was one -- an encode failure here is
    -- about the script's return value, not the tree, so the caller still needs to know
    -- the commit happened (transactionResult), even though the response itself is an error.
    return json.encode({ error = 'failed to encode result: ' .. tostring(encoded) }), nil, committed and 'committed' or nil
  end

  return encoded, nil, committed and 'committed' or nil
end

return M
