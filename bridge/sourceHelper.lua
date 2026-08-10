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

-- Builds a CODE -> {type, options, citation, fdefPtr} map from a resolved template's FDEF
-- children. citation (boolean) is FDEF's own CITN child ("Yes" when present, absent
-- otherwise) -- FH's "Citation-specific" checkbox in the Source Template Field
-- Definition Dialog, live-confirmed (issue #65) to be readable the same way as every
-- other FDEF subfield: a citation-level field's value is populated on the *citation*
-- item, not the Source record itself (see gedcom-knowledge-corpus source-template-fields
-- for the general record-vs-citation distinction, e.g. QUAY/AUTH/TITL) -- findSources
-- below uses this to know which of fieldFilters to check where. fdefPtr (a live pointer
-- to the FDEF item itself, Clone()'d so it survives past this walk) is for shortcutFor
-- below (fhGetMetafieldShortcut also works directly on a metafield *definition* item, per
-- its own FH help page) -- never returned to a caller outside this module, so it never
-- needs to cross the JSON-encode boundary the rest of this map's fields do.
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
          fdefPtr = child:Clone(),
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
-- populate one) or a Data Reference expects to resolve one back (resolvedFieldValue
-- below, both for record-level and citation-level matching, and getPopulatedTemplateFields)
-- -- shared so none of them drift. Delegates to FH's own fhGetMetafieldShortcut on the
-- field definition's live pointer (def.fdefPtr, see fieldDefs above) rather than
-- hand-building "~" .. prefix .. "-" .. code from a maintained TYPE->prefix table: FH's
-- own function is guaranteed to match its real internal form (live-confirmed, issue #73:
-- the real shortcut for a field coded "Reference" is "~TX-REFERENCE", uppercased, not
-- "~TX-Reference" -- Data Reference resolution turned out to be case-insensitive on the
-- code portion so the old hand-built form still worked, but there's no reason to rely on
-- that once FH will just tell us the exact form directly).
local function shortcutFor(def)
  return fhGetMetafieldShortcut(def.fdefPtr)
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
  local item = fhCreateItem(shortcutFor(def), sour)
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
-- positioned by the caller (a Fact-level citation). Errors on an unresolvable source or an
-- invalid ptrTarget before creating anything, so a bad call never leaves a stray citation
-- behind -- the ptrTarget check specifically (same "not ptr or ptr:IsNull()" idiom
-- familyHelper.lua uses throughout) matters beyond tidiness: sandbox.lua's trackedWrite
-- flips the write tracker before fhCreateItem even runs, so an invalid ptrTarget reaching
-- fhCreateItem("SOUR", ptrTarget) unvalidated would arm ADR 0005's rollback/Session-death
-- path for a caller mistake that wrote nothing, exactly like the sessionLogHelper.logActivity
-- gap fixed in issue #95 -- this is that same audit finding it a second time (issue #96).
function M.citeSource(ptrTarget, sourceNameOrId)
  if not ptrTarget or ptrTarget:IsNull() then
    error("citeSource: ptrTarget must point to the record or Fact item to attach the citation to")
  end
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

-- Resolves one field's value directly off ptr via its own ~PREFIX-CODE shortcut Data
-- Reference -- FH's own field-addressing mechanism (gedcom-knowledge-corpus
-- data-references-syntax: "Source Template metafields... addressed... by a shortcut built
-- from the field's 3-letter type prefix + its CODE"). Live-proven correct (issue #67/#73)
-- where two more obvious alternatives aren't: a populated field's real raw tag is
-- "_FIELD" always, never its shortcut string or its CODE, so matching by tag can't
-- distinguish one field from another at all; and matching a source's Nth _FIELD child
-- positionally against its template's Nth FDEF breaks the moment a field partway through
-- is left unpopulated, shifting every later field's answer. ptr may be a SOUR record (a
-- record-level field) or a citation item (a citation-level field, issue #73) -- the
-- resolution is identical either way, since a Data Reference resolves relative to
-- whatever ptr is.
--
-- Returns nil (not "") for "not populated", so it plugs directly into valueMatches below.
local function resolvedFieldValue(ptr, def)
  local value = fhGetItemText(ptr, "~." .. shortcutFor(def))
  if value == "" then
    return nil
  end
  return value
end

-- True if every filters[code] matches ptr's own resolvedFieldValue for that code, per
-- valueMatches' substring-or-exact rule for that code's field type. ptr is a live Item
-- Pointer -- the SOUR record itself for a record-level check, or a citation item for a
-- citation-level one (issue #73) -- not a getAllDetails-shape tree, since
-- resolvedFieldValue needs a live pointer to resolve a Data Reference against. One
-- function serves both cases identically; which fields end up in a given filters table
-- (record-level vs citation-level) is already decided by findSources below, per each
-- field's own CITN flag.
local function matchesFilters(ptr, filters, defs)
  for code, wantedValue in pairs(filters) do
    local value = resolvedFieldValue(ptr, defs[code])
    if not valueMatches(value, wantedValue, defs[code].type) then
      return false
    end
  end
  return true
end

-- fhBridge.getPopulatedTemplateFields(sourPtr)
-- sourPtr may be a live Item Pointer or a qualified id string (e.g. "S1462") -- see
-- familyHelper.resolvePointer, reused here since sourceHelper.lua already require()s
-- familyHelper for getAllDetails. Read-only, wired into BOTH Session modes (same as
-- findSources) -- unlike createSourceFromTemplate/citeSource.
--
-- Resolves sourPtr's linked _SRCT template (via linkedTemplate above) and returns
-- {code = value} for every record-level field that resolves to a non-empty value via
-- resolvedFieldValue above. Returns an empty table (not an error) if sourPtr resolves to a
-- real record that just isn't a templated source -- same "legitimate empty answer, not a
-- failure" philosophy as searchByName/getFactsByTag in familyHelper.lua. sourPtr itself
-- being null is a caller mistake, not that case, so it's rejected the same explicit way as
-- getAllDetails' own null check -- otherwise it would silently read as "not templated"
-- too, masking the actual mistake.
--
-- Scope: record-level fields only -- a Citation-specific field (FDEF's own CITN child) is
-- populated per-citation, not on the SOUR record itself, so it never resolves here even
-- when populated on some citation (see source-template-fields in the
-- gedcom-knowledge-corpus for the general record-vs-citation distinction). findSources
-- above resolves citation-level fields the same way (resolvedFieldValue, matchesFilters),
-- just against a citation's own live pointer instead of sourPtr -- there's no equivalent
-- exported helper for "every populated citation-level field on this specific citation"
-- yet, since nothing has needed one so far; add one the same shape as this function if
-- that changes.
function M.getPopulatedTemplateFields(sourPtr)
  sourPtr = familyHelper.resolvePointer(sourPtr)
  if not sourPtr or sourPtr:IsNull() then
    error("getPopulatedTemplateFields: pointer must not be null")
  end

  local template = linkedTemplate(sourPtr)
  if not template or template:IsNull() then
    return {}
  end

  local result = {}
  for code, def in pairs(fieldDefs(template)) do
    local value = resolvedFieldValue(sourPtr, def)
    if value then
      result[code] = value
    end
  end
  return result
end

-- Recursively scans ptr's own live children for every SOUR-tagged citation at any depth,
-- grouping them by the id of the source each one links to. ownTag/ownQualifiedId identify
-- the enclosing item the citation actually sits on -- the top-level record itself for a
-- Whole-record citation (ownTag starts as the record's own tag, e.g. "INDI"/"FAM"), or the
-- nearest enclosing Fact for a Fact-level one (ownTag becomes that Fact's own tag, e.g.
-- "BIRT", as the walk descends into it) -- matching FH's own "Whole-record vs Fact-level
-- citation" distinction (see run-lua-guidance-cite-every-fact). Same reasoning as
-- checking-for-any-source-citation-is-recursive in the gedcom-knowledge-corpus: a shallow
-- direct-children-only scan would miss most real citations, which sit on a Fact rather
-- than the record itself.
--
-- Walks the live tree directly (MoveToFirstChildItem/MoveNext) rather than a pre-built
-- getAllDetails JSON tree the way this used to (issue #73): each citation's own live
-- pointer is retained (Clone()'d) alongside its tag/qualifiedId, so matchesFilters can
-- resolve a citation-level field by its shortcut Data Reference the same reliable way
-- record-level fields already do -- a JSON tree can't carry a live pointer at all
-- (jsonEncode.lua can't encode one), which is exactly why citation-level matching used to
-- be stuck with a less reliable tag-based tree walk instead.
local function collectCitations(ptr, ownTag, ownQualifiedId, bySourceId)
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(ptr)
  while child:IsNotNull() do
    local childTag = fhGetTag(child)
    if childTag == "SOUR" then
      local target = fhGetValueAsLink(child)
      if target and not target:IsNull() then
        local sourceId = fhGetRecordId(target)
        local list = bySourceId[sourceId]
        if not list then
          list = {}
          bySourceId[sourceId] = list
        end
        table.insert(list, { ptr = child:Clone(), tag = ownTag, qualifiedId = ownQualifiedId })
      end
    end
    collectCitations(child, childTag, ownQualifiedId, bySourceId)
    child:MoveNext()
  end
end

-- One pass over every INDI/FAM record, grouping every SOUR citation found anywhere in the
-- project by the id of the source it links to. Cheaper than re-scanning the whole project
-- once per candidate source below.
local function allCitationsBySourceId()
  local bySourceId = {}
  for _, recTag in ipairs({ "INDI", "FAM" }) do
    local ptr = fhNewItemPtr()
    ptr:MoveToFirstRecord(recTag)
    while ptr:IsNotNull() do
      collectCitations(ptr, fhGetTag(ptr), fhGetQualifiedRecordId(ptr), bySourceId)
      ptr:MoveNext()
    end
  end
  return bySourceId
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
      -- Record-level filters are checked directly off the live pointer (matchesFilters, the
      -- proven-correct resolution) before paying for a full getAllDetails walk -- cheaper
      -- for the common non-matching case, and sourTree is only actually needed once we know
      -- this candidate is worth keeping.
      if matchesFilters(sourPtr, recordFilters, defs) then
        local sourTree = familyHelper.getAllDetails(sourPtr)
        local citationEntries = citationsBySourceId[fhGetRecordId(sourPtr)] or {}
        local citationFiltersOk = next(citationFilters) == nil
        local citedBy = {}
        for _, entry in ipairs(citationEntries) do
          table.insert(citedBy, { tag = entry.tag, qualifiedId = entry.qualifiedId })
          -- Same matchesFilters function as record-level above -- entry.ptr is the
          -- citation's own live pointer (issue #73), resolved the same shortcut-Data-
          -- Reference way rather than the old tag-based tree walk.
          if not citationFiltersOk and matchesFilters(entry.ptr, citationFilters, defs) then
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

-- fhBridge.getTemplateFieldCensus(templateNameOrId)
-- Read-only (wired into both Session modes, same as findSources/getPopulatedTemplateFields
-- -- gating tracks whether a function writes, not which file it lives in). issue #74 (ADR
-- 0017): describe_project's own sourceTemplateFields census used to give this occurrence
-- data (record-level fields only, issue #67/#73) but was found to make every describe_project
-- call pay for a per-SOUR-record field-resolution walk regardless of whether the
-- conversation ever needed it, and even then never covered citation-level (CITN) fields at
-- all -- extending it to do so would mean walking every citation across every INDI/FAM
-- record (allCitationsBySourceId below) on every describe_project call, which recomputes on
-- every call with no caching (ADR 0002). So describe_project's own census is now structural
-- only (field definitions, no counts); this helper gives the actual occurrence counts,
-- opt-in, single-template scoped like findSources/getPopulatedTemplateFields.
--
-- Returns { recordFields = {code = countOfSourRecordsPopulated}, citationFields = {code =
-- countOfCitationsPopulated} } for every field this template defines -- every code
-- present, even ones populated on zero record/citation (0, not omitted), so a caller can
-- tell "never populated" apart from "not a field on this template" (which errors instead,
-- same as findSources/createSourceFromTemplate's own unknown-field-code handling elsewhere
-- in this file). recordFields counts SOUR records (one per source, whether-or-not
-- populated more than once isn't a real state); citationFields counts individual citations
-- (matching how issue #74's own evidence was framed -- "1,108 of 1,196 citations", not
-- "N sources with at least one such citation").
--
-- The whole-project citation walk (allCitationsBySourceId, the same one findSources uses)
-- only runs at all when this template actually defines at least one citation-level field --
-- a template with none never pays for it.
function M.getTemplateFieldCensus(templateNameOrId)
  local template = resolveTemplate(templateNameOrId)
  local templateId = fhGetRecordId(template)
  local defs = fieldDefs(template)

  local recordFields, citationFields = {}, {}
  local hasCitationFields = false
  for code, def in pairs(defs) do
    if def.citation then
      citationFields[code] = 0
      hasCitationFields = true
    else
      recordFields[code] = 0
    end
  end

  local citationsBySourceId = hasCitationFields and allCitationsBySourceId() or nil

  local sourPtr = fhNewItemPtr()
  sourPtr:MoveToFirstRecord("SOUR")
  while sourPtr:IsNotNull() do
    local candidateTemplate = linkedTemplate(sourPtr)
    if candidateTemplate and not candidateTemplate:IsNull() and fhGetRecordId(candidateTemplate) == templateId then
      for code in pairs(recordFields) do
        if resolvedFieldValue(sourPtr, defs[code]) then
          recordFields[code] = recordFields[code] + 1
        end
      end
      if citationsBySourceId then
        local entries = citationsBySourceId[fhGetRecordId(sourPtr)] or {}
        for _, entry in ipairs(entries) do
          for code in pairs(citationFields) do
            if resolvedFieldValue(entry.ptr, defs[code]) then
              citationFields[code] = citationFields[code] + 1
            end
          end
        end
      end
    end
    sourPtr:MoveNext()
  end

  return { recordFields = recordFields, citationFields = citationFields }
end

return M
