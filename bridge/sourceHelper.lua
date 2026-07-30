-- Creates a fully populated templated Source record in one call: resolves an existing
-- _SRCT template record, validates every supplied field against the template's own FDEF
-- field definitions, then creates the SOUR record, its _SRCT link, each metafield, an
-- optional transcription, and refreshes its auto-title. See
-- docs/superpowers/specs/2026-07-30-createSourceFromTemplate-design.md for the full design.
--
-- Calls the real fh* globals directly (not a sandboxed copy), the same way fhUtils does —
-- sandbox.lua must only ever wire this module through during a read-write Session (see its
-- own comment for why).

local M = {}

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

-- Builds a CODE -> {type, options} map from a resolved template's FDEF children.
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

local function validateFields(fields, defs)
  for code, value in pairs(fields) do
    local def = defs[code]
    if not def then
      error("unknown field code '" .. tostring(code) .. "' for this template")
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
    return fhNewDate(value.year, value.month, value.day, value.subtype)
  end
  return value
end

local function setField(sour, code, value, def)
  local shortcut = "~" .. FIELD_TYPE_PREFIX[def.type] .. "-" .. code
  local item = fhCreateItem(shortcut, sour)
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

return M
