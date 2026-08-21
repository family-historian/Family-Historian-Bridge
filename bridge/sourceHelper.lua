-- Creates a fully populated templated Source record in one call (createSourceFromTemplate):
-- resolves a _SRCT template, validates fields against it, creates the SOUR record plus its
-- metafields/transcription, and refreshes its auto-title. Also attaches a SOUR citation to
-- any target item (citeSource), optionally setting standard citation fields
-- (Page/Text/EntryDate/Assessment) and/or template CITN fields in the same call.
--
-- Calls the real fh* globals directly (not sandboxed) -- sandbox.lua only wires
-- createSourceFromTemplate/citeSource through during a read-write Session. findSources is
-- the one exception: a pure-read function, wired through in both access modes.

local M = {}

-- findSources reuses familyHelper.getAllDetails to describe a source's own tree and to
-- recursively find every citation of it, rather than re-walking a record's fields itself.
local familyHelper = require('familyHelper')

-- "~" is the self-reference Data Reference token: "the value at the pointer itself".
local function currentText(ptr)
  return fhGetItemText(ptr, "~")
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
-- children. citation (boolean, from FDEF's CITN child) is FH's "Citation-specific"
-- checkbox -- a citation-level field's value is populated on the citation item, not the
-- Source record itself; findSources uses this to know which of fieldFilters to check
-- where. fdefPtr (Clone()'d) is a live pointer to the FDEF item itself, for shortcutFor
-- below -- never returned outside this module.
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

-- Resolves a tag+id pair to the one record via MoveToRecordById -- ids are only unique
-- within a record type, per FH's own docs, so tag+id is enough. label names the record
-- kind in error messages (e.g. "_SRCT template", "SOUR source").
local function resolveById(tag, label, id)
  local ptr = fhNewItemPtr()
  ptr:MoveToRecordById(tag, id)
  if ptr:IsNull() then
    error("no " .. label .. " record with id " .. tostring(id))
  end
  return ptr
end

-- Resolves nameOrId to the one record: by exact case-insensitive match on
-- readChildText(ptr, nameFieldTag) for a string not shaped like this tag's own qualified
-- id, or by fhGetRecordId for a number or a qualified-id-shaped string (e.g. "S1186" for a
-- SOUR lookup). Errors on zero/multiple name matches or a nonexistent id. label names the
-- record kind in error messages.
--
-- A string shaped like THIS tag's own qualified id always resolves as an id, never as a
-- name match, even if some record's Title happens to read the same way. A string shaped
-- like a DIFFERENT tag's qualified id isn't recognized as an id here at all, and falls
-- through to the name match like any other non-matching string.
local function resolveByNameOrId(tag, nameFieldTag, label, nameOrId)
  if type(nameOrId) == "number" then
    return resolveById(tag, label, nameOrId)
  end

  if type(nameOrId) ~= "string" then
    error(label .. " lookup must be a string (name/title) or number (record id)")
  end

  local qualifiedId = familyHelper.parseQualifiedId(tag, nameOrId)
  if qualifiedId then
    return resolveById(tag, label, qualifiedId)
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

-- Looks up code's field definition in defs, with the "unknown field code" error shared by
-- every caller that validates a code against a resolved template.
local function requireFieldDef(defs, code)
  local def = defs[code]
  if not def then
    error("unknown field code '" .. tostring(code) .. "' for this template")
  end
  return def
end

-- Returns parentPtr's first direct child tagged wantedTag (a live Clone()'d pointer), or
-- nil if none.
local function findChildItem(parentPtr, wantedTag)
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(parentPtr)
  while child:IsNotNull() do
    if fhGetTag(child) == wantedTag then
      return child:Clone()
    end
    child:MoveNext()
  end
  return nil
end

-- Finds the template a SOUR record is linked to (its own _SRCT child's link target), or
-- nil if it isn't a templated source.
local function linkedTemplate(sourPtr)
  local link = findChildItem(sourPtr, "_SRCT")
  return link and fhGetValueAsLink(link)
end

-- The ~PREFIX-CODE shortcut fhCreateItem expects for a metafield, and a Data Reference
-- resolves back to read one -- delegates to FH's own fhGetMetafieldShortcut(def.fdefPtr)
-- rather than hand-building "~"..prefix.."-"..code, since the real shortcut isn't always
-- what a naive prefix+code build would produce (e.g. "Reference" -> "~TX-REFERENCE",
-- uppercased).
local function shortcutFor(def)
  return fhGetMetafieldShortcut(def.fdefPtr)
end

-- expectCitation=false (createSourceFromTemplate's record-level fields) rejects a
-- citation-specific (CITN) code; true (citeSource's template fields) rejects a
-- record-level code instead. Enum-option validation is identical either way.
local function validateFields(fields, defs, expectCitation)
  for code, value in pairs(fields) do
    local def = requireFieldDef(defs, code)
    if expectCitation then
      if not def.citation then
        error("field '" .. code .. "' is record-level and can't be set on a citation - set it when creating the source record instead")
      end
    elseif def.citation then
      error("field '" .. code .. "' is citation-specific and can't be set when creating the record")
    end
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

-- Date fields (a template field typed "Date", or citeSource's EntryDate) accept a Date
-- object, the {year=,month=,day=[,subtype=]} table shorthand, or a plain string -- see
-- familyHelper.resolveDate.
-- The 4 generic citation-specific fields FH's own docs describe (Entry date / Assessment /
-- Where within Source / Text from Source). Reserved citeSource.fields keys, always valid
-- regardless of whether the resolved source is templated. Names mirror the underlying
-- GEDCOM tag where short enough (Page/Text -> PAGE/TEXT), FH's own dialog label otherwise
-- (EntryDate/Assessment).
local STANDARD_CITATION_FIELDS = { Page = true, Text = true, EntryDate = true, Assessment = true }

-- QUAY's real GEDCOM tag is a single certainty digit 0-3, but FH's API exposes/stores it
-- as a human-readable string built from up to 4 independent yes/no axes. Each row is
-- either/or/neither, never both words from the same row.
local ASSESSMENT_ROWS = {
  { "Unreliable", "Questionable" },
  { "Indirect", "Direct" },
  { "Secondary", "Primary" },
  { "Derivative", "Original" },
}

-- Rejects an Assessment string with a word outside the fixed vocabulary, or two words from
-- the same row.
local function validateAssessment(value)
  if value == nil or value == "" then
    return
  end
  if type(value) ~= "string" then
    error("Assessment must be a string")
  end
  local seenRow = {}
  for word in value:gmatch("%S+") do
    local rowIndex = nil
    for i, row in ipairs(ASSESSMENT_ROWS) do
      if word == row[1] or word == row[2] then
        rowIndex = i
        break
      end
    end
    if not rowIndex then
      error("invalid Assessment word '" .. word .. "' - must be one of: Unreliable/Questionable, Indirect/Direct, Secondary/Primary, Derivative/Original")
    end
    if seenRow[rowIndex] then
      error("Assessment can't include both words from the same row (row " .. rowIndex .. ")")
    end
    seenRow[rowIndex] = true
  end
end

-- Page/Text get minimal type checks; EntryDate is left to resolveDate/fhNewDate to reject
-- a malformed value.
local function validateStandardFields(fields)
  if fields.Page ~= nil and type(fields.Page) ~= "string" then
    error("Page must be a string")
  end
  if fields.Text ~= nil and type(fields.Text) ~= "string" then
    error("Text must be a string")
  end
  validateAssessment(fields.Assessment)
end

-- Splits citeSource's fields table into standard vs template fields -- a reserved
-- standard-field key always wins over a same-named template field code.
local function splitCitationFields(fields)
  local standard, template = {}, {}
  for code, value in pairs(fields) do
    if STANDARD_CITATION_FIELDS[code] then
      standard[code] = value
    else
      template[code] = value
    end
  end
  return standard, template
end

-- Text and EntryDate both nest under one shared DATA child of the citation, per GEDCOM's
-- SOUR > DATA > {DATE, TEXT} structure; PAGE and QUAY are direct citation children instead
-- (SOUR > PAGE, SOUR > QUAY). Reuses an existing DATA child rather than creating a second
-- one if both are supplied in the same call.

-- Best-effort description of a write-result error's target: sour may be a real record
-- (fhGetQualifiedRecordId resolves it) or a citation sub-item, which has no qualified id
-- -- falls back to naming the item's own tag.
local function describeTarget(ptr)
  local qid = fhGetQualifiedRecordId(ptr)
  if qid ~= "" then
    return qid
  end
  return "this " .. fhGetTag(ptr) .. " item"
end

local function citationDataItem(citation)
  local existing = findChildItem(citation, "DATA")
  if existing then
    return existing
  end
  local data = fhCreateItem("DATA", citation)
  familyHelper.checkCreated(data, "citeSource: failed to create the DATA item on " .. describeTarget(citation))
  return data
end

local function setStandardField(citation, code, value)
  local target = describeTarget(citation)
  if code == "Page" then
    local item = fhCreateItem("PAGE", citation)
    familyHelper.checkCreated(item, "citeSource: failed to create standard field 'Page' (PAGE) on " .. target)
    familyHelper.checkWrite(fhSetValueAsText(item, value), "citeSource: failed to write standard field 'Page' on " .. target)
  elseif code == "Assessment" then
    local item = fhCreateItem("QUAY", citation)
    familyHelper.checkCreated(item, "citeSource: failed to create standard field 'Assessment' (QUAY) on " .. target)
    familyHelper.checkWrite(fhSetValueAsText(item, value), "citeSource: failed to write standard field 'Assessment' on " .. target)
  elseif code == "Text" then
    local data = citationDataItem(citation)
    local item = fhCreateItem("TEXT", data)
    familyHelper.checkCreated(item, "citeSource: failed to create standard field 'Text' (DATA.TEXT) on " .. target)
    familyHelper.checkWrite(fhSetValueAsRichText(item, fhNewRichText(value, false)), "citeSource: failed to write standard field 'Text' on " .. target)
  elseif code == "EntryDate" then
    local data = citationDataItem(citation)
    local item = fhCreateItem("DATE", data)
    familyHelper.checkCreated(item, "citeSource: failed to create standard field 'EntryDate' (DATA.DATE) on " .. target)
    familyHelper.checkWrite(fhSetValueAsDate(item, familyHelper.resolveDate(value, "citeSource")), "citeSource: failed to write standard field 'EntryDate' on " .. target)
  end
end

local function setField(sour, value, def, code, callerName)
  local item = fhCreateItem(shortcutFor(def), sour)
  familyHelper.checkCreated(item, callerName .. ": failed to create field '" .. code .. "' (" .. shortcutFor(def) .. ") on " .. describeTarget(sour))
  local message = callerName .. ": failed to write field '" .. code .. "' on " .. describeTarget(sour)
  if def.type == "Date" then
    familyHelper.checkWrite(fhSetValueAsDate(item, familyHelper.resolveDate(value, callerName)), message)
  elseif def.type == "Repository" then
    familyHelper.checkWrite(fhSetValueAsLink(item, value), message)
  else
    -- Text, Name, Place, Address, Enum, URL all land via the same plain-string setter.
    familyHelper.checkWrite(fhSetValueAsText(item, value), message)
  end
end

-- sourceHelper.validateCreateSourceFromTemplate(templateNameOrId, fields)
-- The validation half of createSourceFromTemplate, extracted so sandbox.lua can call it
-- before arming the write tracker -- a rejected call here should never look like a write.
-- Returns the resolved template pointer and its field-def map, both needed for the actual
-- create step.
function M.validateCreateSourceFromTemplate(templateNameOrId, fields)
  local template = resolveTemplate(templateNameOrId)
  local defs = fieldDefs(template)
  validateFields(fields or {}, defs)
  return template, defs
end

-- sourceHelper.createSourceFromTemplate(templateNameOrId, fields, transcription)
-- Validates everything before any fhCreateItem call, so a bad call never leaves a
-- partially-created record behind.
function M.createSourceFromTemplate(templateNameOrId, fields, transcription)
  fields = fields or {}

  local template, defs = M.validateCreateSourceFromTemplate(templateNameOrId, fields)

  local sour = fhCreateItem("SOUR")
  familyHelper.checkCreated(sour, "createSourceFromTemplate: failed to create the SOUR record")
  local link = fhCreateItem("_SRCT", sour)
  familyHelper.checkCreated(link, "createSourceFromTemplate: failed to create the source's _SRCT template link")
  familyHelper.checkWrite(fhSetValueAsLink(link, template), "createSourceFromTemplate: failed to link the source to its template")

  for code, value in pairs(fields) do
    setField(sour, value, defs[code], code, "createSourceFromTemplate")
  end

  if transcription then
    local text = fhCreateItem("TEXT", sour)
    familyHelper.checkCreated(text, "createSourceFromTemplate: failed to create the source's TEXT (transcription) field")
    familyHelper.checkWrite(fhSetValueAsRichText(text, fhNewRichText(transcription, false)), "createSourceFromTemplate: failed to write the source's transcription")
  end

  fhSrcEnableAutoTitle(sour, true)

  return {
    id = fhGetRecordId(sour),
    title = currentText(sour),
  }
end

-- sourceHelper.validateCiteSource(ptrTarget, sourceNameOrId, fields)
-- The validation half of citeSource, extracted so sandbox.lua can call it before arming
-- the write tracker. Returns the resolved source pointer, the split standard/template
-- field tables, and (when the source is templated) its field-def map.
--
-- fields is optional, covering two families in one flat table: the 4 reserved standard
-- citation fields (Page/Text/EntryDate/Assessment, always valid) and a template's own
-- citation-specific (CITN) field codes (only valid when the source is templated). A
-- reserved standard-field key always wins over a same-named template CITN field code --
-- if the template defines one, it's rejected outright with a clear collision error rather
-- than silently misrouting the caller's value. A record-level (non-CITN) template field
-- sharing a reserved name isn't flagged, since citeSource never accepts record-level
-- fields anyway.
function M.validateCiteSource(ptrTarget, sourceNameOrId, fields)
  local problem = familyHelper.pointerProblem(ptrTarget)
  if problem then
    error("citeSource: ptrTarget must point to the record or Fact item to attach the citation to" .. problem)
  end
  local source = resolveSource(sourceNameOrId)
  fields = fields or {}

  local standardFields, templateFields = splitCitationFields(fields)
  validateStandardFields(standardFields)

  local defs = nil
  if next(fields) ~= nil then
    local template = linkedTemplate(source)
    if template and not template:IsNull() then
      defs = fieldDefs(template)
      for code in pairs(standardFields) do
        if defs[code] and defs[code].citation then
          error("field '" .. code .. "' is defined by this source's template as a citation-specific field, which collides with the reserved standard citation field of the same name - rename the template field, or omit '" .. code .. "' from this call's fields and set the template field manually (fhGetMetafieldShortcut + fhCreateItem + fhSetValueAsText) on the citation pointer a fields-less citeSource call returns")
        end
      end
    end
    if next(templateFields) ~= nil then
      if not defs then
        error("citeSource: source '" .. currentText(source) .. "' has no template - can't set citation-specific template fields on an untemplated source")
      end
      validateFields(templateFields, defs, true)
    end
  end

  return source, standardFields, templateFields, defs
end

-- sourceHelper.citeSource(ptrTarget, sourceNameOrId, fields)
-- Attaches a SOUR citation to ptrTarget, resolving the source the same by-id-or-title way
-- createSourceFromTemplate resolves a template. ptrTarget may be an INDI/FAM record (a
-- Whole-record citation) or any Fact item already positioned by the caller (a Fact-level
-- citation). Validates everything (validateCiteSource) before creating anything.
--
-- Returns the created citation's own live pointer, not a qualifiedId -- a citation is a
-- child item, not a standalone record -- so a caller can keep working on it directly
-- within the same run_lua call.
function M.citeSource(ptrTarget, sourceNameOrId, fields)
  local source, standardFields, templateFields, defs = M.validateCiteSource(ptrTarget, sourceNameOrId, fields)
  local citation = fhCreateItem("SOUR", ptrTarget)
  familyHelper.checkCreated(citation, "citeSource: failed to create the citation on " .. describeTarget(ptrTarget))
  familyHelper.checkWrite(fhSetValueAsLink(citation, source), "citeSource: failed to link the citation to its source")

  for code, value in pairs(standardFields) do
    setStandardField(citation, code, value)
  end
  for code, value in pairs(templateFields) do
    setField(citation, value, defs[code], code, "citeSource")
  end

  return citation
end

-- Field types whose fieldFilters value is matched exactly, not as a substring: Enum
-- (a fixed dropdown), Date and Repository (compared as their rendered display text, the
-- same text getAllDetails already shows). Every other type gets a case-insensitive
-- substring match.
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

-- Resolves one field's value directly off ptr via its own ~PREFIX-CODE shortcut Data
-- Reference -- FH's own field-addressing mechanism. Matching by tag can't distinguish
-- fields (a populated field's raw tag is always "_FIELD"), and matching by child position
-- against the template's Nth FDEF breaks the moment an earlier field is left unpopulated.
-- ptr may be a SOUR record or a citation item -- resolution is identical either way.
--
-- Returns nil (not "") for "not populated", so it plugs directly into valueMatches.
local function resolvedFieldValue(ptr, def)
  local value = fhGetItemText(ptr, "~." .. shortcutFor(def))
  if value == "" then
    return nil
  end
  return value
end

-- True if every filters[code] matches ptr's own resolvedFieldValue for that code. ptr is
-- the SOUR record itself for a record-level check, or a citation item for a
-- citation-level one.
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
-- sourPtr: live pointer or qualified id string. Read-only, wired into both Session modes.
--
-- Resolves sourPtr's linked template and returns {code = value} for every record-level
-- field with a non-empty value. Returns an empty table (not an error) if sourPtr is a real
-- record that just isn't templated; a null sourPtr is still rejected as a caller mistake.
--
-- Scope: record-level fields only -- a citation-specific field is populated per-citation,
-- not on the SOUR record itself, so it never resolves here.
function M.getPopulatedTemplateFields(sourPtr)
  sourPtr = familyHelper.resolvePointer(sourPtr)
  local problem = familyHelper.pointerProblem(sourPtr)
  if problem then
    error("getPopulatedTemplateFields: pointer must not be null" .. problem)
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

-- fhGetRecordLinks(sourPtr) returns each linking item itself (issue #66; live-confirmed
-- against a running Bridge -- item-level, arbitrary depth, not resolved up to a record).
-- For a SOUR target, that's the citation item (tag "SOUR") directly. MoveToParentItem
-- gives the enclosing Fact/record's own tag (ownTag); MoveToRecordItem gives the owning
-- INDI/FAM (ownQualifiedId). The citation's own live pointer (Clone()'d) is retained --
-- needed for matchesFilters to resolve a citation-level field by its shortcut Data
-- Reference, which a JSON tree can't carry.
local function citationsForSource(sourPtr)
  local entries = {}
  for _, citationPtr in ipairs(fhGetRecordLinks(sourPtr)) do
    if fhGetTag(citationPtr) == "SOUR" then
      local parent = fhNewItemPtr()
      parent:MoveToParentItem(citationPtr)
      local owner = fhNewItemPtr()
      owner:MoveToRecordItem(citationPtr)
      local ownerTag = fhGetTag(owner)
      if ownerTag == "INDI" or ownerTag == "FAM" then
        table.insert(entries, {
          ptr = citationPtr:Clone(),
          tag = fhGetTag(parent),
          qualifiedId = fhGetQualifiedRecordId(owner),
        })
      end
    end
  end
  return entries
end

-- sourceHelper.findSources(templateNameOrId, fieldFilters)
-- Read-only, wired through in both Session modes. Finds every SOUR record linked to the
-- given template whose populated fields match every fieldFilters entry: {[fieldCode] =
-- matchValue} -- substring (case-insensitive) or exact per field type (EXACT_MATCH_TYPES).
-- Which of fieldFilters is checked against the record's own fields vs. its citations'
-- fields is decided per field by the template's CITN flag, not by the caller -- a
-- citation-level entry matches if ANY citation of the candidate source matches. Errors on
-- a field code not defined on the template; an unpopulated code on a given candidate just
-- fails to match, same as any other value.
--
-- Returns an array of { source = <getAllDetails tree>, citedBy = array of {tag,
-- qualifiedId} for every fact/record citing it }. citedBy is always present, even with no
-- fieldFilters, so a caller can see how a template is actually used.
function M.findSources(templateNameOrId, fieldFilters)
  fieldFilters = fieldFilters or {}

  local template = resolveTemplate(templateNameOrId)
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

  local results = {}
  local seen = {}
  -- fhGetRecordLinks(template) returns the linking _SRCT item itself (issue #66) --
  -- MoveToRecordItem climbs to the owning SOUR record. Replaces the old whole-SOUR-table
  -- scan + linkedTemplate(sourPtr) check.
  for _, linkItem in ipairs(fhGetRecordLinks(template)) do
    local sourPtr = fhNewItemPtr()
    sourPtr:MoveToRecordItem(linkItem)
    local recordId = fhGetRecordId(sourPtr)
    if fhGetTag(sourPtr) == "SOUR" and not seen[recordId] then
      seen[recordId] = true
      -- Record-level filters are checked off the live pointer first (cheap) -- sourTree is
      -- only built once we know this candidate is worth keeping.
      if matchesFilters(sourPtr, recordFilters, defs) then
        local sourTree = familyHelper.getAllDetails(sourPtr)
        local citationEntries = citationsForSource(sourPtr)
        local citationFiltersOk = next(citationFilters) == nil
        local citedBy = {}
        for _, entry in ipairs(citationEntries) do
          table.insert(citedBy, { tag = entry.tag, qualifiedId = entry.qualifiedId })
          if not citationFiltersOk and matchesFilters(entry.ptr, citationFilters, defs) then
            citationFiltersOk = true
          end
        end
        if citationFiltersOk then
          table.insert(results, { source = sourTree, citedBy = citedBy })
        end
      end
    end
  end

  return results
end

-- fhBridge.getTemplateFieldCensus(templateNameOrId)
-- Read-only, wired into both Session modes. Gives per-field occurrence counts for one
-- template, since describe_project's own census is structural only (field definitions, no
-- counts -- ADR 0017) to avoid paying for a full field-resolution walk on every call.
--
-- Returns { recordFields = {code = countOfSourRecordsPopulated}, citationFields = {code =
-- countOfCitationsPopulated} } for every field the template defines -- every code present
-- even at 0, so "never populated" is distinguishable from "not a field on this template"
-- (which errors, same as findSources/createSourceFromTemplate). recordFields counts SOUR
-- records; citationFields counts individual citations.
--
-- The per-source citation walk (citationsForSource) only runs when the template defines at
-- least one citation-level field.
function M.getTemplateFieldCensus(templateNameOrId)
  local template = resolveTemplate(templateNameOrId)
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

  local seen = {}
  -- fhGetRecordLinks(template) returns the linking _SRCT item itself (issue #66) --
  -- MoveToRecordItem climbs to the owning SOUR record. Replaces the old whole-SOUR-table
  -- scan + linkedTemplate(sourPtr) check.
  for _, linkItem in ipairs(fhGetRecordLinks(template)) do
    local sourPtr = fhNewItemPtr()
    sourPtr:MoveToRecordItem(linkItem)
    local recordId = fhGetRecordId(sourPtr)
    if fhGetTag(sourPtr) == "SOUR" and not seen[recordId] then
      seen[recordId] = true
      for code in pairs(recordFields) do
        if resolvedFieldValue(sourPtr, defs[code]) then
          recordFields[code] = recordFields[code] + 1
        end
      end
      if hasCitationFields then
        for _, entry in ipairs(citationsForSource(sourPtr)) do
          for code in pairs(citationFields) do
            if resolvedFieldValue(entry.ptr, defs[code]) then
              citationFields[code] = citationFields[code] + 1
            end
          end
        end
      end
    end
  end

  return { recordFields = recordFields, citationFields = citationFields }
end

return M
