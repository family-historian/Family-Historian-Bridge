-- fhBridge.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge): creates a
-- Fact (an event or attribute -- BIRT, CENS, OCCU, etc.) on an INDI or FAM record via
-- fhUtils.createFact. Citing the new fact is a separate step (sourceHelper.citeSource, not
-- this module) -- M.createFact returns the new fact's own live pointer, so a caller can
-- chain straight into citeSource(thatPointer, ...) within the same run_lua call.
--
-- Calls the real fhUtils global directly (not the sandboxed env.fhu proxy), the same way
-- sourceHelper.lua/sessionLogHelper.lua/richTextHelper.lua call real fh* globals directly
-- -- sandbox.lua only wires fhBridge.createFact through during a read-write Session.
-- fhUtils is required lazily, inside M.createFact rather than at module top-level, so a
-- test process that only exercises M.validateCreateFact never needs a fhUtils stub.

local M = {}

local familyHelper = require('familyHelper')

-- factHelper.validateCreateFact(ptrRecord, sTag, sPlace, dtDate)
-- The validation half of M.createFact, called by sandbox.lua on its own, untracked,
-- before arming the write tracker. ptrRecord may be a live Item Pointer or a qualified id
-- string (e.g. "I219", "F3") via familyHelper.resolvePointer, but never a bare number --
-- fhu.createFact accepts either an INDI or a FAM record, so a number alone can't say which.
--
-- _sPlace (leading underscore, luacheck's "deliberately unused" convention) exists purely
-- for positional alignment with M.createFact's own signature -- sandbox.lua calls this
-- with the SAME raw args a real call receives, positionally, so dtDate must sit at the
-- same 4th-argument position here as in M.createFact, or it silently binds to sPlace's
-- slot instead.
--
-- dtDate goes through familyHelper.resolveDate (a Date object, the {year=,month=,day=}
-- table shorthand, or a plain string), resolved and validated here before M.createFact
-- calls fhu.createFact, so a malformed date rejects cleanly instead of creating the Fact
-- item first.
--
-- Returns the resolved pointer and the resolved Date value, both needed by M.createFact.
-- Doesn't validate sAddress/sValue/sAge -- fhu.createFact itself skips any that are nil,
-- and this project trusts the caller for the rest.
function M.validateCreateFact(ptrRecord, sTag, _sPlace, dtDate)
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
-- Creates a new Fact on ptrRecord via fhu.createFact, which skips any of
-- sPlace/dtDate/sAddress/sValue/sAge that are nil. dtDate is resolved via
-- familyHelper.resolveDate first (see validateCreateFact above). sAge only applies to an
-- Individual attribute fact per fhUtils' own docs -- not enforced here, same
-- "trust the caller" stance sPlace/sAddress/sValue already get.
--
-- Returns the new Fact's own live pointer, not a qualifiedId -- a Fact is a sub-item, not
-- a standalone record -- so a caller can chain into fhBridge.citeSource(thatPointer, ...)
-- within the same run_lua call (citeSource accepts any Fact item as its ptrTarget for a
-- Fact-level citation, per ADR 0006).
--
-- fhu.createFact's own failure contract only documents "Returns: new fact record pointer",
-- with no failure case named. familyHelper.checkCreated is still the right check
-- regardless: it treats a Lua nil, a genuinely-null Item Pointer, or any other
-- wrong-shaped return value as the same "problem" case.
function M.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge)
  local ptr, resolvedDate = M.validateCreateFact(ptrRecord, sTag, sPlace, dtDate)
  local fhu = require('fhUtils')
  local fact = fhu.createFact(ptr, sTag, sPlace, resolvedDate, sAddress, sValue, sAge)
  familyHelper.checkCreated(fact, "createFact: fhu.createFact failed to create a " .. sTag ..
    " fact on " .. fhGetQualifiedRecordId(ptr))
  return fact
end

return M
