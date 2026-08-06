-- Creates a fully populated templated Source record in one call: resolves an existing
-- _SRCT template record, validates every supplied field against the template's own FDEF
-- field definitions, then creates the SOUR record, its _SRCT link, each metafield, an
-- optional transcription, and refreshes its auto-title. See
-- docs/superpowers/specs/2026-07-30-createSourceFromTemplate-design.md for the full design.
--
-- Calls the real fh* globals directly (not a sandboxed copy), the same way fhUtils does —
-- sandbox.lua must only ever wire createSourceFromTemplate/citeSource through during a
-- read-write Session (see its own comment for why). findSources (issue #65) is the one
-- exception: a pure-read function, wired through in BOTH access modes, same as
-- familyHelper.lua's members -- see sandbox.lua's own comment on why gating tracks
-- whether a function writes, not which file it lives in.

local M = {}

-- findSources (below) reuses familyHelper.getAllDetails rather than re-walking/
-- re-describing a Source record's fields itself, both for the SOUR record's own tree
-- (the .source field in its result) and to recursively find every citation of it across
-- the project (getAllDetails already walks a record's full child tree, same as the
-- gedcom-knowledge-corpus's checking-for-any-source-citation-is-recursive entry does for
-- a single Individual).
local familyHelper = require('familyHelper')

-- ~PREFIX-CODE metafield shortcut prefixes, per FH's own "Metafields and Shortcuts" help
-- and the gedcom-knowledge-corpus "Creating a templated Source record" entry.
local FIELD_TYPE_PREFIX = {
  Text = "TX",
  Name = "NM",
  Place = "PL",
  Address = "AD",
  Enum = "EN",
  Date = "DT",
  Repository = "RP",
  URL = "UL",
}

-- "~" is the self-reference Data Reference token (see the '~.NAME'/'~:SURNAME' qualifier
-- examples in the gedcom-knowledge-corpus and the FH API's own fhGetItemText examples) —
-- it means "the value at the pointer itself", with no further child/qualifier navigation.
local function currentText(ptr)
  return fhGetItemText(ptr, "~")
end

-- Walks tag-typed records (e.g. "_SRCT"), returning a pointer positioned at the first one
-- where predicate(ptr) is true, or nil if none match.
local function findRecord(tag, predicate)
  local ptr = fhNewItemPtr()
  ptr:MoveToFirstRecord(tag)
  while ptr:IsNotNull() do
    if predicate(ptr) then
      return ptr
    end
    ptr:MoveNext()
  end
  return nil
end

-- Reads the text value of the first direct child of parentPtr tagged wantedTag, or nil if
-- there is none. Used for the NAME/CODE/TYPE/PROM subfields on _SRCT and FDEF items.
local function readChildText(parentPtr, wantedTag)
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(parentPtr)
  while child:IsNotNull() do
    if fhGetTag(child) == wantedTag then
      return currentText(child)
    end
    child:MoveNext()
  end
  return nil
end

local function parseOptions(prom)
  if not prom or prom == "" then
    return nil
  end
  local options = {}
  for opt in string.gmatch(prom, "([^|]+)") do
    table.insert(options, opt:match("^%s*(.-)%s*$"))
  end
  return options
end

-- Builds a CODE -> {type, options, citation} map from a resolved template's FDEF
-- children. citation (boolean) is FDEF's own CITN child ("Yes" when present, absent
-- otherwise) -- FH's "Citation-specific" checkbox in the Source Template Field
-- Definition Dialog, live-confirmed (issue #65) to be readable the same way as every
-- other FDEF subfield: a citation-level field's value is populated on the *citation*
-- item, not the Source record itself (see gedcom-knowledge-corpus source-template-fields
-- for the general record-vs-citation distinction, e.g. QUAY/AUTH/TITL) -- findSources
-- below uses this to know which of fieldFilters to check where.
local function fieldDefs(srctPtr)
  local defs = {}
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(srctPtr)
  while child:IsNotNull() do
    if fhGetTag(child) == "FDEF" then
      local code = readChildText(child, "CODE")
      if code then
        defs[code] = {
          type = readChildText(child, "TYPE"),
          options = parseOptions(readChildText(child, "PROM")),
          citation = readChildText(child, "CITN") == "Yes",
        }
      end
    end
    child:MoveNext()
  end
  return defs
end

-- Resolves nameOrId to the one record: tag whose readChildText(ptr, nameFieldTag) matches
-- nameOrId case-insensitively (string form), or whose fhGetRecordId matches exactly
-- (number form). Errors on zero or multiple matches. Deliberately walks records by tag
-- rather than using MoveToRecordById, since a number here means "match this id among
-- tag records specifically", not "any record with this id". label names the record kind
-- in error messages (e.g. "_SRCT template", "SOUR source").
local function resolveByNameOrId(tag, nameFieldTag, label, nameOrId)
  if type(nameOrId) == "number" then
    local match = findRecord(tag, function(ptr)
      return fhGetRecordId(ptr) == nameOrId
    end)
    if not match then
      error("no " .. label .. " record with id " .. tostring(nameOrId))
    end
    return match
  end

  if type(nameOrId) ~= "string" then
    error(label .. " lookup must be a string (name/title) or number (record id)")
  end

  local wanted = nameOrId:lower()
  local matches = {}
  local ptr = fhNewItemPtr()
  ptr:MoveToFirstRecord(tag)
  while ptr:IsNotNull() do
    local name = readChildText(ptr, nameFieldTag)
    if name and name:lower() == wanted then
      table.insert(matches, ptr:Clone())
    end
    ptr:MoveNext()
  end

  if #matches == 0 then
    error("no " .. label .. " found named '" .. nameOrId .. "'")
  end
  if #matches > 1 then
    error(#matches .. " " .. label .. "s found named '" .. nameOrId .. "' - resolve by id instead")
  end
  return matches[1]
end

local function resolveTemplate(templateNameOrId)
  return resolveByNameOrId("_SRCT", "NAME", "_SRCT template", templateNameOrId)
end

local function resolveSource(sourceNameOrId)
  return resolveByNameOrId("SOUR", "TITL", "SOUR source", sourceNameOrId)
end

-- Looks up code's field definition in defs, erroring with the same "unknown field code"
-- message every caller that validates a code against a resolved template's fields wants
-- (createSourceFromTemplate's validateFields below, and findSources' filter-splitting
-- further down) -- shared so the two don't drift.
local function requireFieldDef(defs, code)
  local def = defs[code]
  if not def then
    error("unknown field code '" .. tostring(code) .. "' for this template")
  end
  return def
end

-- The ~PREFIX-CODE shortcut fhCreateItem expects for a metafield (setField below, to
-- populate one) or the exact child tag it lands as (findSources further down, to read
-- one back) -- shared so the two don't drift.
local function shortcutFor(def, code)
  return "~" .. FIELD_TYPE_PREFIX[def.type] .. "-" .. code
end

local function validateFields(fields, defs)
  for code, value in pairs(fields) do
    local def = requireFieldDef(defs, code)
    if def.type == "Enum" then
      local ok = false
      for _, opt in ipairs(def.options or {}) do
        if opt == value then
          ok = true
          break
        end
      end
      if not ok then
        error("invalid value '" .. tostring(value) .. "' for Enum field '" .. code .. "'")
      end
    end
  end
end

-- fields may supply a Date already built via fhNewDate, or the {year=,month=,day=
-- [,subtype=]} table shorthand — only the latter is a plain Lua table.
local function toDate(value)
  if type(value) == "table" then
    return fhNewDate(value.year, value.month, value.day, value.subtype)
  end
  return value
end

local function setField(sour, code, value, def)
  local item = fhCreateItem(shortcutFor(def, code), sour)
  if def.type == "Date" then
    fhSetValueAsDate(item, toDate(value))
  elseif def.type == "Repository" then
    fhSetValueAsLink(item, value)
  else
    -- Text, Name, Place, Address, Enum, URL all land via the same plain-string setter.
    fhSetValueAsText(item, value)
  end
end

-- sourceHelper.createSourceFromTemplate(templateNameOrId, fields, transcription)
-- See the design spec for the full contract. Validates everything (steps 1-3) before any
-- fhCreateItem call (step 4), so a bad call never leaves a partially-created record behind.
function M.createSourceFromTemplate(templateNameOrId, fields, transcription)
  fields = fields or {}

  local template = resolveTemplate(templateNameOrId)
  local defs = fieldDefs(template)

  validateFields(fields, defs)

  local sour = fhCreateItem("SOUR")
  local link = fhCreateItem("_SRCT", sour)
  fhSetValueAsLink(link, template)

  for code, value in pairs(fields) do
    setField(sour, code, value, defs[code])
  end

  if transcription then
    local text = fhCreateItem("TEXT", sour)
    fhSetValueAsRichText(text, fhNewRichText(transcription, false))
  end

  fhSrcEnableAutoTitle(sour, true)

  return {
    id = fhGetRecordId(sour),
    title = currentText(sour),
  }
end

-- sourceHelper.citeSource(ptrTarget, sourceNameOrId)
-- Attaches a SOUR citation to ptrTarget, resolving the source the same by-id-or-by-title
-- way createSourceFromTemplate resolves a template. ptrTarget may be an INDI/FAM record
-- (a Whole-record citation, per FH's own "citation for the record as a whole" concept —
-- see docs/adr/0006-cite-every-fact-a-source-supports.md) or any Fact item already
-- positioned by the caller (a Fact-level citation). Errors on an unresolvable source
-- before creating anything, so a bad call never leaves a stray citation behind.
function M.citeSource(ptrTarget, sourceNameOrId)
  local source = resolveSource(sourceNameOrId)
  local citation = fhCreateItem("SOUR", ptrTarget)
  fhSetValueAsLink(citation, source)
end

-- Field types whose fieldFilters value is matched exactly, not as a substring -- Enum
-- (a fixed dropdown, so "close" is meaningless), Date and Repository (compared as their
-- rendered display text -- the same fhGetDisplayText(ptr, "~", "min") rendering
-- describeItem/getAllDetails already uses for every field's .value -- rather than as a
-- structured Date/link comparison, so a caller matches what getAllDetails already showed
-- them). Every other type (Text/Name/Place/Address/URL) is free-form enough that a
-- case-insensitive substring match is more useful than requiring an exact string.
local EXACT_MATCH_TYPES = { Enum = true, Date = true, Repository = true }

local function fieldValueFromTree(tree, shortcut)
  for _, child in ipairs(tree.children or {}) do
    if child.tag == shortcut then
      return child.value
    end
  end
  return nil
end

local function valueMatches(value, wantedValue, fieldType)
  if value == nil then
    return false
  end
  if EXACT_MATCH_TYPES[fieldType] then
    return value == wantedValue
  end
  return tostring(value):lower():find(tostring(wantedValue):lower(), 1, true) ~= nil
end

-- Finds the template a SOUR record is linked to (its own _SRCT child's link target), or
-- nil if it isn't a templated source at all.
local function linkedTemplate(sourPtr)
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(sourPtr)
  while child:IsNotNull() do
    if fhGetTag(child) == "_SRCT" then
      return fhGetValueAsLink(child)
    end
    child:MoveNext()
  end
  return nil
end

-- Recursively scans a getAllDetails-shape tree (already walked once by the caller) for
-- every SOUR-tagged citation at any depth, grouping them by the id of the source each
-- one links to. ownTag/ownQualifiedId identify the enclosing item the citation actually
-- sits on -- the top-level record itself for a Whole-record citation (ownTag starts as
-- the record's own tag, e.g. "INDI"/"FAM"), or the nearest enclosing Fact for a
-- Fact-level one (ownTag becomes that Fact's own tag, e.g. "BIRT", as the walk descends
-- into it) -- matching FH's own "Whole-record vs Fact-level citation" distinction (see
-- run-lua-guidance-cite-every-fact). Same reasoning as
-- checking-for-any-source-citation-is-recursive in the gedcom-knowledge-corpus: a
-- shallow direct-children-only scan would miss most real citations, which sit on a Fact
-- rather than the record itself.
local function collectCitations(node, ownTag, ownQualifiedId, bySourceId)
  for _, child in ipairs(node.children or {}) do
    if child.tag == "SOUR" and child.link and child.link.id then
      local list = bySourceId[child.link.id]
      if not list then
        list = {}
        bySourceId[child.link.id] = list
      end
      table.insert(list, { node = child, tag = ownTag, qualifiedId = ownQualifiedId })
    end
    collectCitations(child, child.tag, ownQualifiedId, bySourceId)
  end
end

-- One pass over every INDI/FAM record's full detail tree, grouping every SOUR citation
-- found anywhere in the project by the id of the source it links to. Cheaper than
-- re-scanning the whole project once per candidate source below.
local function allCitationsBySourceId()
  local bySourceId = {}
  for _, recTag in ipairs({ "INDI", "FAM" }) do
    local ptr = fhNewItemPtr()
    ptr:MoveToFirstRecord(recTag)
    while ptr:IsNotNull() do
      local tree = familyHelper.getAllDetails(ptr)
      collectCitations(tree, tree.tag, tree.qualifiedId, bySourceId)
      ptr:MoveNext()
    end
  end
  return bySourceId
end

-- True if every filters[code] matches tree's own child tagged shortcutByCode[code], per
-- valueMatches' substring-or-exact rule for that code's field type. Module-level (not a
-- closure over findSources' own locals) so its signature states exactly what it needs,
-- matching this file's other helpers (fieldValueFromTree, valueMatches, linkedTemplate,
-- collectCitations).
local function treeMatchesFilters(tree, filters, defs, shortcutByCode)
  for code, wantedValue in pairs(filters) do
    local value = fieldValueFromTree(tree, shortcutByCode[code])
    if not valueMatches(value, wantedValue, defs[code].type) then
      return false
    end
  end
  return true
end

-- sourceHelper.findSources(templateNameOrId, fieldFilters)
-- Read-only (see sandbox.lua -- unlike createSourceFromTemplate/citeSource, wired through
-- in both Read-only and Read-write Sessions). Finds every SOUR record linked to the given
-- template whose populated fields match every fieldFilters entry: {[fieldCode] =
-- matchValue}, e.g. {Registration_District = "Barnstaple"} -- matching is substring
-- (case-insensitive) or exact per field type, see EXACT_MATCH_TYPES above. Which of
-- fieldFilters is checked against the SOUR record's own fields vs. against its
-- citations' fields is decided per field by the template's own CITN flag (fieldDefs
-- above), not by the caller -- a citation-level fieldFilters entry matches a candidate
-- source if ANY of its citations (anywhere in the project) has a matching value, since a
-- template's citation-level fields are populated per-citation, not once for the source
-- as a whole. Errors on a field code that isn't defined on this template at all (same
-- validation as createSourceFromTemplate); a field code that's merely unpopulated on a
-- given candidate source just fails to match that candidate, same as any other value.
--
-- Returns an array of { source = <getAllDetails-shape tree for the SOUR record>, citedBy
-- = array of {tag, qualifiedId} for every fact/record that cites it, across every
-- INDI/FAM in the project } -- citedBy is unconditional (present even with no
-- fieldFilters, and even when a match came from record-level fields alone), so a caller
-- can see how a template is actually used (e.g. "usually cited on BIRT plus a dated
-- OCCU") without a second helper call.
function M.findSources(templateNameOrId, fieldFilters)
  fieldFilters = fieldFilters or {}

  local template = resolveTemplate(templateNameOrId)
  local templateId = fhGetRecordId(template)
  local defs = fieldDefs(template)

  local shortcutByCode = {}
  for code, def in pairs(defs) do
    shortcutByCode[code] = shortcutFor(def, code)
  end

  local recordFilters, citationFilters = {}, {}
  for code, wantedValue in pairs(fieldFilters) do
    local def = requireFieldDef(defs, code)
    if def.citation then
      citationFilters[code] = wantedValue
    else
      recordFilters[code] = wantedValue
    end
  end

  local citationsBySourceId = allCitationsBySourceId()

  local results = {}
  local sourPtr = fhNewItemPtr()
  sourPtr:MoveToFirstRecord("SOUR")
  while sourPtr:IsNotNull() do
    local candidateTemplate = linkedTemplate(sourPtr)
    if candidateTemplate and not candidateTemplate:IsNull() and fhGetRecordId(candidateTemplate) == templateId then
      local sourTree = familyHelper.getAllDetails(sourPtr)
      if treeMatchesFilters(sourTree, recordFilters, defs, shortcutByCode) then
        local citationEntries = citationsBySourceId[fhGetRecordId(sourPtr)] or {}
        local citationFiltersOk = next(citationFilters) == nil
        local citedBy = {}
        for _, entry in ipairs(citationEntries) do
          table.insert(citedBy, { tag = entry.tag, qualifiedId = entry.qualifiedId })
          if not citationFiltersOk and treeMatchesFilters(entry.node, citationFilters, defs, shortcutByCode) then
            citationFiltersOk = true
          end
        end
        if citationFiltersOk then
          table.insert(results, { source = sourTree, citedBy = citedBy })
        end
      end
    end
    sourPtr:MoveNext()
  end

  return results
end

return M
