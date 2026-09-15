-- fhBridge.getTftfText / fhBridge.setTftfText: a safe way to edit IN THE MIDDLE of an
-- existing large RichText field (Notes, Source TEXT, citation DATA/TEXT), not just append
-- to the end of it.
--
-- The problem: RichText:SetText(sText, bRich, false, tblRecLinks, tblCitations) -- the
-- eFTF path -- only works as an exact, unmodified passthrough of a field's own last
-- GetText() result; any hand-extension of tblRecLinks returns false silently.
-- AddText/AddRecordLink only append to the end of a field's current content. Neither
-- approach can splice new content into the middle of an existing field.
--
-- The fix: tFTF's <rec=QualifiedId,...> syntax embeds the record's own qualified id
-- directly in the text, with no side table at all -- RichText:SetText(text, true, true)
-- ignores tblRecLinks entirely. getTftfText converts a field's GetText()-returned eFTF
-- text (index-based <rec=N,...> + tblRecLinks) into a self-contained tFTF string; a caller
-- can splice/insert/reorder that plain string with ordinary Lua string operations and
-- commit it in one setTftfText call.
--
-- What this does NOT solve: tFTF cannot represent source citations at all (FH's own
-- documented limit). Worse, SetText(text, true, true) does not error on a <cit=N> marker
-- -- it silently accepts it, the marker becomes dead literal text, and the citation is
-- gone with no warning. Both functions below refuse outright whenever the target field's
-- own GetText() reports any embedded citations. Use eFTF/AddCitation directly for citation
-- work, or ask the user to edit that field by hand in FH.

local M = {}

-- Reused for the shared pcall-guarded pointer check (familyHelper.pointerProblem) that
-- getTftfText/validateSetTftfText's own ptr checks below use instead of their own copy of
-- the "not ptr or ptr:IsNull()" idiom.
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

-- The validation half of setTftfText, checked up front, untracked, so sandbox.lua's write
-- tracker never arms for a call rejected here. Re-checks for citations at write time (not
-- just whatever getTftfText saw earlier) in case the field gained one by hand in FH's own
-- UI between calls.
function M.validateSetTftfText(ptr, text)
  local problem = familyHelper.pointerProblem(ptr)
  if problem then
    error("setTftfText: ptr must point to the rich-text field to write" .. problem)
  end
  -- ptr is always a field (Notes/Source TEXT/citation DATA-TEXT), never the record
  -- itself, so recordVisibility needs the owning record -- climbed onto a separate
  -- pointer, since ptr must still point at the field for the write below (issue #141).
  local owner = fhNewItemPtr()
  owner:MoveToRecordItem(ptr)
  if familyHelper.recordVisibility(owner) == "exclude" then
    error("setTftfText: this Individual is Excluded by the Session's Visibility settings")
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
  familyHelper.checkWrite(fhSetValueAsRichText(ptr, rt), "setTftfText: failed to write - FH declined the write to this '" .. fhGetTag(ptr) .. "' field")
end

return M
