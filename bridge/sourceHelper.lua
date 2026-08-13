-- Creates a fully populated templated Source record in one call: resolves an existing
-- _SRCT template record, validates every supplied field against the template's own FDEF
-- field definitions, then creates the SOUR record, its _SRCT link, each metafield, an
-- optional transcription, and refreshes its auto-title. See
-- docs/superpowers/specs/2026-07-30-createSourceFromTemplate-design.md for the full design.
-- Also creates a SOUR citation on any target item (citeSource), optionally populating its
-- own standard citation fields (Page/Text/EntryDate/Assessment) and/or a template's
-- citation-specific (CITN) fields in the same call (issue #99).
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
-- nameOrId case-insensitively (string form, not shaped like this tag's own qualified id),
-- or whose fhGetRecordId matches exactly (number form, or a qualified-id-shaped string
-- form -- issue #100, e.g. "S1186" for a SOUR lookup). Errors on zero or multiple Title/
-- NAME matches, or on an id (either form) that doesn't exist. Deliberately walks records
-- by tag rather than using MoveToRecordById, since an id here means "match this id among
-- tag records specifically", not "any record with this id". label names the record kind
-- in error messages (e.g. "_SRCT template", "SOUR source").
--
-- Precedence (issue #100): a string shaped like THIS tag's own qualified id
-- (familyHelper.parseQualifiedId(tag, nameOrId) returning non-nil) always resolves as an
-- id -- it is never also attempted against Title/NAME, even if some record's Title
-- literally reads the same way (e.g. a SOUR titled "S78" is not reachable via the string
-- "S78" once a real id 78 exists) -- matching familyHelper.resolvePointer's own
-- "any qualified id string is always an id, never a name" precedent, the closest existing
-- rule in this codebase. A string shaped like a DIFFERENT tag's qualified id (e.g. "T4"
-- passed to a SOUR lookup) is not recognized as an id at all here -- parseQualifiedId is
-- tag-scoped and returns nil -- so it falls through to the Title/NAME match below the
-- same as any other non-matching string, rather than silently resolving the wrong tag.
local function resolveById(tag, label, id)
  local match = findRecord(tag, function(ptr)
    return fhGetRecordId(ptr) == id
  end)
  if not match then
    error("no " .. label .. " record with id " .. tostring(id))
  end
  return match
end

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

-- Returns parentPtr's first direct child tagged wantedTag (a live Clone()'d pointer), or
-- nil if it has none -- shared by linkedTemplate (below, a link-valued child) and
-- citationDataItem (issue #99, a complex/record-valued child), the same "walk children,
-- match by tag" loop both used to hand-roll separately.
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
-- nil if it isn't a templated source at all. Moved above validateFields/validateCiteSource
-- (issue #99) so citeSource's own validation can resolve a source's template without a
-- forward reference -- findSources/getTemplateFieldCensus further down still use it the
-- same way.
local function linkedTemplate(sourPtr)
  local link = findChildItem(sourPtr, "_SRCT")
  return link and fhGetValueAsLink(link)
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

-- expectCitation (issue #99) flips which side of the record-vs-citation distinction is
-- rejected: false/nil (createSourceFromTemplate's own record-level fields, the original
-- issue #98 behavior) rejects a citation-specific (CITN) code; true (citeSource's own
-- template fields) rejects a record-level (non-CITN) code instead, with a matching
-- clear-error message rather than createSourceFromTemplate's. Enum-option validation is
-- identical either way, so it isn't duplicated per caller.
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

-- fields may supply a Date already built via fhNewDate, or the {year=,month=,day=
-- [,subtype=]} table shorthand — only the latter is a plain Lua table.
local function toDate(value)
  if type(value) == "table" then
    -- fhNewDate's strSubType is documented optional (fhNewDate.htm:
    -- "fhNewDate([iYear[, iMonth [, iDay [, strSubType]]]])"), but live-confirmed
    -- (issue #99, discovered via live testing) that FH's binding rejects an explicit nil
    -- in that 4th slot ("bad argument #4 to 'fhNewDate' (string expected, got nil)")
    -- rather than treating it the same as the argument being omitted entirely -- so
    -- value.subtype being nil (the common case: no subtype in the table shorthand) must
    -- drop the argument, not pass it through as nil. Pre-existing bug, not new to issue
    -- #99's own EntryDate field -- createSourceFromTemplate's own Date fields share this
    -- same function and were equally exposed; the unit-test fake didn't catch it because
    -- its own fhNewDate stub tolerated a nil 4th argument where real FH's doesn't.
    if value.subtype then
      return fhNewDate(value.year, value.month, value.day, value.subtype)
    end
    return fhNewDate(value.year, value.month, value.day)
  end
  return value
end

-- The 4 generic citation-specific fields FH's own help documents (sourcesandsourcetemplates
-- .html: "generic citation-specific fields... Entry date / Assessment / Where within Source
-- / Text from Source") -- issue #99, the follow-up #98's own closing comment deliberately
-- left untracked. Reserved citeSource.fields keys, always valid regardless of whether the
-- resolved source is templated at all (unlike a template's own CITN fields, below, which
-- only exist when it is). Names chosen to mirror the underlying GEDCOM tag directly where
-- there is one short enough to read on sight (Page/Text, matching GEDCOM's own PAGE/TEXT --
-- see this file's other GEDCOM-tag-named fields QUAY/AUTH/TITL in CONTEXT.md), and FH's own
-- dialog label otherwise (EntryDate/Assessment, since DATA.DATE/QUAY have no single-word
-- GEDCOM tag a caller would recognize unaided).
local STANDARD_CITATION_FIELDS = { Page = true, Text = true, EntryDate = true, Assessment = true }

-- QUAY's real GEDCOM tag is a single certainty digit 0-3, but FH's plugin API exposes and
-- stores it as a human-readable, space-separated string built from up to 4 independent
-- yes/no axes -- live-confirmed, FH developer response, issue #32 (see
-- citation-quality-assessment-quay in the gedcom-knowledge corpus). Each row is
-- either/or/neither, never both words from the same row.
local ASSESSMENT_ROWS = {
  { "Unreliable", "Questionable" },
  { "Indirect", "Direct" },
  { "Secondary", "Primary" },
  { "Derivative", "Original" },
}

-- Rejects an Assessment string containing a word outside the fixed vocabulary, or two
-- words from the same row -- same rigor this file already applies to a template's own
-- closed Enum option lists (validateFields above), rather than passing an unvalidated
-- string through to fhSetValueAsText, which doesn't reject bad input on its own.
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

-- Page/Text minimal type checks -- Enum-grade closed-vocabulary validation only applies to
-- Assessment (above); EntryDate is left to toDate/fhNewDate to reject a genuinely malformed
-- value, same as a template Date field already does.
local function validateStandardFields(fields)
  if fields.Page ~= nil and type(fields.Page) ~= "string" then
    error("Page must be a string")
  end
  if fields.Text ~= nil and type(fields.Text) ~= "string" then
    error("Text must be a string")
  end
  validateAssessment(fields.Assessment)
end

-- Splits a citeSource fields table into its two families (issue #99): reserved standard-
-- field keys always win over a same-named template field code (see the collision check in
-- M.validateCiteSource below) -- a flat merged table matches createSourceFromTemplate's own
-- convention rather than introducing a namespaced shape just for the rare collision case.
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

-- Text and EntryDate both nest under one shared DATA child of the citation, per GEDCOM
-- 5.5.1's own SOURCE_CITATION structure (SOUR > DATA > {DATE, TEXT}) -- cross-confirmed
-- against fhUtils.createTextFromSource's own doc ("Creates or updates a TEXT item from
-- rich text and attaches it to a source or citation DATA"), a different Lua API surface
-- than this file uses but the same live data model underneath. PAGE and QUAY are direct
-- citation children instead (GEDCOM SOUR > PAGE, SOUR > QUAY, siblings of DATA). Reuses an
-- existing DATA child rather than creating a second one if Text and EntryDate are both
-- supplied in the same call.
local function citationDataItem(citation)
  return findChildItem(citation, "DATA") or fhCreateItem("DATA", citation)
end

local function setStandardField(citation, code, value)
  if code == "Page" then
    fhSetValueAsText(fhCreateItem("PAGE", citation), value)
  elseif code == "Assessment" then
    fhSetValueAsText(fhCreateItem("QUAY", citation), value)
  elseif code == "Text" then
    local data = citationDataItem(citation)
    fhSetValueAsRichText(fhCreateItem("TEXT", data), fhNewRichText(value, false))
  elseif code == "EntryDate" then
    local data = citationDataItem(citation)
    fhSetValueAsDate(fhCreateItem("DATE", data), toDate(value))
  end
end

local function setField(sour, value, def)
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

-- sourceHelper.validateCreateSourceFromTemplate(templateNameOrId, fields)
-- The pure validation half of M.createSourceFromTemplate below (steps 1-3 of the design
-- spec's "validate everything, then mutate" order), extracted (issue #97) so sandbox.lua can
-- call it on its own, untracked, before arming the write tracker -- flipping tracker.wrote
-- purely from entering the wrapped fhBridge.createSourceFromTemplate call (as the old
-- single-function wrapping did) meant even a call rejected right here still armed ADR 0005's
-- rollback path, for a call that (by definition, once this errors) never reached
-- fhCreateItem. Returns the resolved template pointer and its CODE -> field-def map, both
-- of which M.createSourceFromTemplate itself needs for step 4 -- so it also calls this
-- first (rather than duplicating steps 1-3), keeping today's single-call, validate-then-
-- mutate contract unchanged for direct callers/tests.
function M.validateCreateSourceFromTemplate(templateNameOrId, fields)
  local template = resolveTemplate(templateNameOrId)
  local defs = fieldDefs(template)
  validateFields(fields or {}, defs)
  return template, defs
end

-- sourceHelper.createSourceFromTemplate(templateNameOrId, fields, transcription)
-- See the design spec for the full contract. Validates everything (steps 1-3, delegated to
-- validateCreateSourceFromTemplate above) before any fhCreateItem call (step 4), so a bad
-- call never leaves a partially-created record behind.
function M.createSourceFromTemplate(templateNameOrId, fields, transcription)
  fields = fields or {}

  local template, defs = M.validateCreateSourceFromTemplate(templateNameOrId, fields)

  local sour = fhCreateItem("SOUR")
  local link = fhCreateItem("_SRCT", sour)
  fhSetValueAsLink(link, template)

  for code, value in pairs(fields) do
    setField(sour, value, defs[code])
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

-- sourceHelper.validateCiteSource(ptrTarget, sourceNameOrId, fields)
-- The pure validation half of M.citeSource below, extracted (issue #97) so sandbox.lua can
-- call it on its own, untracked, before arming the write tracker -- same rationale as
-- validateCreateSourceFromTemplate above: flipping tracker.wrote purely from entering the
-- wrapped fhBridge.citeSource call armed ADR 0005's rollback path even for a ptrTarget/
-- sourceNameOrId rejected right here, before fhCreateItem ever ran. Returns the resolved
-- source pointer, the split standard/template field tables, and (only when the source is
-- templated) its field-def map -- everything M.citeSource itself needs, so it also calls
-- this first rather than duplicating any of it, keeping today's single-call,
-- validate-then-mutate contract unchanged for direct callers/tests. The ptrTarget check
-- itself (same "not ptr or ptr:IsNull()" idiom familyHelper.lua uses throughout) was added
-- in issue #96, the same audit that found the sessionLogHelper.logActivity gap fixed in
-- issue #95.
--
-- fields (issue #99, follow-up to #98's own closing comment) is optional, covering two
-- families in one flat table: the 4 reserved standard citation fields (Page/Text/
-- EntryDate/Assessment, STANDARD_CITATION_FIELDS above -- always valid, templated or not)
-- and a template's own citation-specific (CITN) field codes (only valid when the resolved
-- source is actually templated). A reserved standard-field key always wins over a
-- same-named template CITN field code -- if the resolved template happens to define one,
-- that template field becomes unreachable through this table, so it's rejected outright
-- with a clear error naming the collision, rather than silently routing the caller's value
-- to the standard field instead of the template field they may have meant. A record-level
-- (non-CITN) template field sharing a reserved name isn't a real collision and isn't
-- flagged -- it was never reachable through citeSource's fields regardless of naming,
-- since citeSource only ever accepts CITN fields (see validateFields's expectCitation
-- branch below), so there's no caller intent this could actually be misrouting.
function M.validateCiteSource(ptrTarget, sourceNameOrId, fields)
  if not ptrTarget or ptrTarget:IsNull() then
    error("citeSource: ptrTarget must point to the record or Fact item to attach the citation to")
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
-- Attaches a SOUR citation to ptrTarget, resolving the source the same by-id-or-by-title
-- way createSourceFromTemplate resolves a template. ptrTarget may be an INDI/FAM record
-- (a Whole-record citation, per FH's own "citation for the record as a whole" concept —
-- see docs/adr/0006-cite-every-fact-a-source-supports.md) or any Fact item already
-- positioned by the caller (a Fact-level citation). Errors on an unresolvable source, an
-- invalid ptrTarget, or an invalid fields entry (all delegated to validateCiteSource above)
-- before creating anything, so a bad call never leaves a stray citation behind.
--
-- Returns the created citation's own live item Pointer (issue #99) -- not a qualifiedId,
-- since a citation is a child item nested under a record/Fact, not a standalone record
-- with one of its own -- so a caller can keep working on it directly (e.g. an FTF-authored
-- Text beyond what fields' plain-string Text supports) within the same run_lua call.
function M.citeSource(ptrTarget, sourceNameOrId, fields)
  local source, standardFields, templateFields, defs = M.validateCiteSource(ptrTarget, sourceNameOrId, fields)
  local citation = fhCreateItem("SOUR", ptrTarget)
  fhSetValueAsLink(citation, source)

  for code, value in pairs(standardFields) do
    setStandardField(citation, code, value)
  end
  for code, value in pairs(templateFields) do
    setField(citation, value, defs[code])
  end

  return citation
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
