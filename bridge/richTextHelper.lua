-- fhBridge.getTftfText / fhBridge.setTftfText (issue #107, 2026-08-15 grilling session,
-- docs/adr/0025-tftf-full-rewrite-for-mid-document-richtext-edit.md): a safe way to edit
-- IN THE MIDDLE of an existing large RichText field (Notes, Source TEXT, citation
-- DATA/TEXT), not just append to the end of it.
--
-- The problem this solves (run-lua-guidance-mid-document-richtext-edit-unconfirmed /
-- run-lua-guidance-settext-reclinks-cannot-add-new-links in the gedcom-knowledge-corpus,
-- issues #106/#107): RichText:SetText(sText, bRich, false, tblRecLinks, tblCitations) --
-- the eFTF path -- only works as an exact, unmodified passthrough of a field's own last
-- GetText() result. Any hand-extension of tblRecLinks, even a correctly-shaped brand-new
-- table, returns false silently (live-tested twice, issue #106). AddText/AddRecordLink on
-- a live-fetched RichText object only appends to the END of its current content, so
-- neither approach can splice new content into the middle of an existing field.
--
-- The fix: tFTF's <rec=QualifiedId,...> syntax embeds the record's own qualified id
-- (fhGetQualifiedRecordId) directly in the text, with no side table at all --
-- RichText:SetText(text, true, true) ignores tblRecLinks entirely, so it structurally
-- cannot hit the #106 bug. getTftfText converts a field's GetText()-returned eFTF text
-- (index-based <rec=N,...> + tblRecLinks) into a self-contained tFTF string; a caller can
-- then splice/insert/reorder that plain string anywhere (including a brand-new
-- <rec=I67,...> tag mid-document) using ordinary Lua string operations, and commit the
-- whole thing in one setTftfText call. Live-verified end to end against Family Historian
-- Sample Project 8 (2026-08-15 grilling session): a two-link document, rebuilt via this
-- exact technique with a new link spliced into the middle, round-tripped correctly through
-- a real fhSetValueAsRichText write and a fresh fhGetValueAsRichText re-read.
--
-- The one thing this does NOT solve: tFTF cannot represent source citations at all (FH's
-- own documented limit, not this project's). Worse, SetText(text, true, true) does not
-- error on text containing a <cit=N> marker -- confirmed live -- it silently accepts it,
-- the marker becomes dead literal text, and the citation is gone with no warning. Both
-- functions below refuse outright (rather than risk that silent loss) whenever the target
-- field's own GetText() reports any embedded citations at all. There is currently no known
-- side-table-free equivalent for citations the way tFTF gives one for record links --
-- editing a citation-bearing field's interior remains an open problem (deliberately out of
-- scope here; see docs/adr/0025's own text). Use eFTF/AddCitation directly for citation
-- work, or ask the user to edit that field by hand in FH.

local M = {}

-- Reused for the shared pcall-guarded pointer check (pointerProblem, issue #110,
-- docs/adr/0027) that getTftfText/validateSetTftfText's own ptr checks below now use
-- instead of their own copy of the "not ptr or ptr:IsNull()" idiom -- familyHelper.lua
-- has no require()s of its own, so this introduces no cycle.
local familyHelper = require('familyHelper')

local function countTableEntries(t)
  if not t then
    return 0
  end
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  return count
end

-- Rebuilds sText (eFTF, as returned by RichText:GetText()) into a self-contained tFTF
-- string: every <rec=N,...> index reference becomes <rec=QualifiedId,...>, resolved via
-- fhGetQualifiedRecordId against tblRecLinks[N]. A Null linked pointer (the target record
-- was since deleted -- GetText()'s own documented possibility) is left as its original
-- numeric index rather than guessed at; tFTF gracefully falls back to display text for an
-- unresolvable qualified id, the same degradation FH's own docs describe for an invalid one.
local function toSelfContainedTftf(sText, tblRecLinks)
  if not tblRecLinks then
    return sText
  end
  local converted = sText
  for index, linkedPtr in pairs(tblRecLinks) do
    if linkedPtr and linkedPtr:IsNotNull() then
      local qualifiedId = fhGetQualifiedRecordId(linkedPtr)
      converted = converted:gsub("<rec=" .. index .. ",", "<rec=" .. qualifiedId .. ",")
    end
  end
  return converted
end

-- Pure read: fetches ptr's current rich-text content as a self-contained tFTF string,
-- ready to splice/edit with plain Lua string operations and hand to setTftfText. Works
-- under both access modes -- fhGetValueAsRichText and fhGetQualifiedRecordId are both
-- already unrestricted reads (see sandbox.lua).
function M.getTftfText(ptr)
  local problem = familyHelper.pointerProblem(ptr)
  if problem then
    error("getTftfText: ptr must point to the rich-text field to read" .. problem)
  end

  local rt = fhGetValueAsRichText(ptr)
  local sText, bRich, tblRecLinks, tblCitations = rt:GetText()

  local citationCount = countTableEntries(tblCitations)
  if citationCount > 0 then
    return {
      text = sText,
      editable = false,
      reason = "this field has " .. citationCount .. " embedded source citation(s); " ..
        "tFTF syntax cannot represent citations, and rewriting this field's text via " ..
        "SetText(text, true, true) silently discards them with no error -- edit via " ..
        "eFTF/AddCitation instead, or ask the user to edit this field by hand in FH",
    }
  end

  if not bRich then
    -- Plain text: already a valid (degenerate) tFTF string, nothing to convert.
    return { text = sText, editable = true }
  end

  return { text = toSelfContainedTftf(sText, tblRecLinks), editable = true }
end

-- Pure validation half of setTftfText (issue #97 pattern, mirrors
-- sourceHelper.validateCiteSource/sessionLogHelper.validateLogActivity): checked up front,
-- untracked, so sandbox.lua's write tracker never arms for a call rejected here. Re-checks
-- for citations at write time (not just whatever getTftfText saw earlier) in case the field
-- gained a citation by hand in FH's own UI between a getTftfText call and this one.
function M.validateSetTftfText(ptr, text)
  local problem = familyHelper.pointerProblem(ptr)
  if problem then
    error("setTftfText: ptr must point to the rich-text field to write" .. problem)
  end
  if type(text) ~= "string" then
    error("setTftfText: text must be a string in tFTF syntax")
  end

  local existing = fhGetValueAsRichText(ptr)
  local _, _, _, tblCitations = existing:GetText()
  local citationCount = countTableEntries(tblCitations)
  if citationCount > 0 then
    error("setTftfText: this field already has " .. citationCount .. " embedded source " ..
      "citation(s); rewriting it via tFTF would silently discard them -- refusing. Edit " ..
      "via eFTF/AddCitation instead, or ask the user to edit this field by hand in FH")
  end
end

-- Commits text (self-contained tFTF, as returned by getTftfText and then edited) as ptr's
-- new rich-text value in one full-document rewrite. Read-write only -- calls the real
-- fhSetValueAsRichText write primitive (see sandbox.lua's validatedTrackedWrite wiring).
function M.setTftfText(ptr, text)
  M.validateSetTftfText(ptr, text)
  local rt = fhNewRichText()
  rt:SetText(text, true, true)
  fhSetValueAsRichText(ptr, rt)
end

return M
