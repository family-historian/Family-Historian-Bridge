-- Executes a run_lua script inside the sandbox and returns a JSON-encoded response string
-- -- either the script's own returned value, or a JSON error object on failure. Ties
-- sandbox.lua and jsonEncode.lua together; no socket/IUP/FH dependency of its own, so
-- (unlike bridge.fh_lua's dialog/socket plumbing) this is testable standalone.
--
-- accessMode defaults to "read-only" (mirroring sandbox.build()'s own default) -- M.run
-- needs a resolved value for the pre-scan below before sandbox.build ever runs.

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

-- Shared shape for a write-mode response that FH's own auto-undo should act on: a JSON
-- error carrying writeSessionRolledBack: true, plus the original error/message as a second
-- return value the caller re-raises after sending. Both the write-mode-runtime-error path
-- and the write-then-log runtime backstop build this same shape.
local function rollbackResponse(message)
  return json.encode({ error = tostring(message), writeSessionRolledBack = true }), message
end

function M.run(scriptText, accessMode)
  accessMode = accessMode or 'read-only'

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
  if #violations > 0 then
    return json.encode({ error = table.concat(violations, '; ') })
  end

  local envOk, env, tracker = pcall(sandbox.build, accessMode)
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
    -- isn't proof of execution (dead code, indirection, partial logging). Same response
    -- shape as the write-mode-runtime-error path below, feeding the same rollback/auto-undo
    -- mechanism.
    return rollbackResponse('script wrote to the tree without logging the activity via fhBridge.logActivity')
  end

  if not ok then
    -- Only a write-mode script that actually called a tracked write primitive before
    -- erroring can have partially mutated the tree. When the tracker fired, report the
    -- error as normal but also hand the caller the raw error, to be re-raised after sending
    -- in a way that actually ends the whole plugin -- the only way to give FH's own
    -- auto-undo a real chance to fire (an error raised from inside a timer callback alone
    -- never escapes the plugin).
    if accessMode == 'read-write' and tracker.wrote then
      return rollbackResponse(result)
    end
    return json.encode({ error = tostring(result) })
  end

  local encodeOk, encoded = pcall(json.encode, result)
  if not encodeOk then
    return json.encode({ error = 'failed to encode result: ' .. tostring(encoded) })
  end

  return encoded
end

return M
