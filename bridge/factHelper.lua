-- fhBridge.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge) (issue #113):
-- creates a Fact (an event or attribute -- BIRT, CENS, OCCU, etc.) on an INDI or FAM record
-- via fhUtils.createFact, replacing the hand-rolled fhCreateItem+fhSetValueAs* dance a
-- previous session hand-rolled ad hoc. Citing the new fact is a separate, deliberate step --
-- sourceHelper.citeSource, not this module (docs/adr/0006-cite-every-fact-a-source-supports.md)
-- -- so M.createFact below returns the new fact's own live item Pointer, letting a caller
-- chain straight into citeSource(thatPointer, ...) within the same run_lua call.
--
-- Calls the real fhUtils global directly (not the sandboxed env.fhu proxy), the same way
-- sourceHelper.lua/sessionLogHelper.lua/richTextHelper.lua call real fh* globals directly --
-- sandbox.lua must only ever wire fhBridge.createFact through during a read-write Session
-- (see its own comment for why). fhUtils itself is required lazily, inside M.createFact
-- rather than at module top-level, the same pattern sessionSettings.lua's load()/save() use
-- (and for the same reason: a test process that only exercises M.validateCreateFact never
-- needs a package.loaded.fhUtils stub at all).

local M = {}

local familyHelper = require('familyHelper')

-- factHelper.validateCreateFact(ptrRecord, sTag, sPlace, dtDate)
-- The pure validation half of M.createFact below (issue #97 pattern: sandbox.lua calls this
-- on its own, untracked, before arming the write tracker, so a rejected call never arms ADR
-- 0005's rollback path). ptrRecord may be a live Item Pointer or a qualified id string (e.g.
-- "I219", "F3") -- familyHelper.resolvePointer -- but never a bare number: fhUtils.createFact
-- accepts either an INDI or a FAM record, so a number alone can't say which (the same
-- ambiguity familyHelper.getAllDetails/getFactsByTag already reject, issue #65) --
-- resolvePointer's own bare-number rejection covers this, no separate check needed here.
--
-- sPlace is declared here purely for positional alignment with M.createFact's own call
-- signature, NOT because it's validated -- sandbox.lua's validatedTrackedWrite calls this
-- with the SAME raw args a real fhBridge.createFact(...) call receives (positionally, not
-- by name), so dtDate MUST sit at the same 4th-argument position here as it does in
-- M.createFact's own signature below, or it silently binds to sPlace's value instead (a
-- real bug this project shipped and live-caught, Family Historian Sample Project 8, issue
-- #113: fhBridge.createFact(p, "CENS", "Newtown", "1905") validated "Newtown" as dtDate and
-- silently dropped "1905" entirely, before this fix added the sPlace placeholder).
--
-- dtDate (docs/adr/0030) goes through familyHelper.resolveDate -- accepts a Date object, the
-- {year=,month=,day=[,subtype=]} table shorthand, or a plain string (parsed via FH's own
-- Date object string parser, fhNewDate():SetValueAsText) -- resolved and validated here,
-- before M.createFact ever calls fhu.createFact, so a malformed date rejects cleanly instead
-- of creating the Fact item first and only failing (and rolling back) on the DATE subfield
-- write, which is what a raw string used to do (live-confirmed, before docs/adr/0030's fix).
--
-- Returns the resolved pointer and the resolved Date value, both of which M.createFact
-- itself also needs -- same "validate once, mutate reuses the result" contract as
-- sourceHelper.lua's validateCreateSourceFromTemplate/validateCiteSource.
--
-- Doesn't take M.createFact's remaining sAddress/sValue/sAge -- there's nothing to validate
-- about them (fhu.createFact itself skips any that are nil, and this project's own stance is
-- to trust the caller and let FH reject a genuinely nonsensical value). sandbox.lua's
-- validatedTrackedWrite still calls this with all 7 args every real call passes -- Lua
-- silently ignores the extra ones past sPlace/dtDate, same as any function called with more
-- args than it declares.
function M.validateCreateFact(ptrRecord, sTag, sPlace, dtDate)
  local ptr = familyHelper.resolvePointer(ptrRecord)
  local problem = familyHelper.pointerProblem(ptr)
  if problem then
    error("createFact: ptrRecord must point to a live INDI or FAM record" .. problem)
  end
  if type(sTag) ~= "string" or sTag == "" then
    error("createFact: sTag must be a non-empty fact tag string (e.g. 'BIRT')")
  end
  local resolvedDate = familyHelper.resolveDate(dtDate, "createFact")
  return ptr, resolvedDate
end

-- factHelper.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge)
-- Creates a new Fact on ptrRecord via fhu.createFact (fhUtils.md's own
-- "fhUtils.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge)" -- Returns:
-- new fact record pointer), which itself skips any of sPlace/dtDate/sAddress/sValue/sAge
-- that are nil. dtDate is resolved via familyHelper.resolveDate first (see
-- validateCreateFact above) -- a Date object, the {year=,month=,day=[,subtype=]} table
-- shorthand, or a plain string are all accepted; a genuinely unrecognized string errors
-- before fhu.createFact ever runs.
-- sAge only applies to an Individual attribute fact per fhUtils' own docs -- not enforced
-- here, same "trust the caller" stance sPlace/sAddress/sValue already get.
--
-- Returns the new Fact's own live item Pointer -- fhu.createFact's own documented return
-- value, passed straight through, not a qualifiedId, since a Fact is a sub-item of its
-- record, not a standalone record with a qualified id of its own. This lets a caller chain
-- straight into fhBridge.citeSource(thatPointer, sourceNameOrId, fields) within the same
-- run_lua call -- sourceHelper.citeSource's own doc comment explicitly accepts "any Fact
-- item already positioned by the caller" as its ptrTarget for a Fact-level citation (ADR
-- 0006), matching citeSource's own return-the-pointer precedent (issue #99).
--
-- fhu.createFact's own failure contract isn't documented beyond "Returns: new fact record
-- pointer" -- no failure case named at all, unlike fhCreateItem's explicit "NULL pointer if
-- the create fails for any reason". familyHelper.checkCreated below is still the right check
-- regardless: it reuses pointerProblem, which already treats a Lua nil, a genuinely-null
-- Item Pointer, and any other wrong-shaped return value as the same "problem" case
-- (familyHelper.lua's own pointerProblem comment) -- so it degrades to a clear error under
-- any of those shapes, not just the one fhCreateItem itself documents.
function M.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge)
  local ptr, resolvedDate = M.validateCreateFact(ptrRecord, sTag, sPlace, dtDate)
  local fhu = require('fhUtils')
  local fact = fhu.createFact(ptr, sTag, sPlace, resolvedDate, sAddress, sValue, sAge)
  familyHelper.checkCreated(fact, "createFact: fhu.createFact failed to create a " .. sTag ..
    " fact on " .. fhGetQualifiedRecordId(ptr))
  return fact
end

return M
