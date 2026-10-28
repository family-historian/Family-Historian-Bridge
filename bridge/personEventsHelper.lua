-- Person-centred view of recorded events. Calls the real fh* globals directly (not
-- sandboxed); sandbox.lua wires it through as fhBridge.getPersonEvents.

local M = {}

local familyHelper = require('familyHelper')

-- opts key -> fhIndGetFactList parameter, in call order, with each flag's default.
local OPTION_FLAGS = {
  { key = "witness", default = true },
  { key = "timeline", default = false },
  { key = "timelinePrefsOnly", default = false },
  { key = "narrative", default = false },
  { key = "resolveExclusions", default = false },
  { key = "excludePrivate", default = false },
  { key = "excludeRejected", default = true },
}

local OPTION_NAMES = {}
for _, flag in ipairs(OPTION_FLAGS) do table.insert(OPTION_NAMES, flag.key) end

local function factListFlags(opts)
  opts = opts or {}
  local known = {}
  for _, flag in ipairs(OPTION_FLAGS) do known[flag.key] = true end
  for key in pairs(opts) do
    if not known[key] then
      error("getPersonEvents: unknown option '" .. tostring(key) .. "' -- valid options are " ..
        table.concat(OPTION_NAMES, ", "))
    end
  end
  local flags = {}
  for i, flag in ipairs(OPTION_FLAGS) do
    local value = opts[flag.key]
    if value == nil then
      value = flag.default
    elseif type(value) ~= "boolean" then
      error("getPersonEvents: option '" .. flag.key .. "' must be true or false, got " .. type(value))
    end
    flags[i] = value
  end
  return flags
end

local function childrenWithTag(ptr, tag)
  local found = {}
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(ptr)
  while child:IsNotNull() do
    if fhGetTag(child) == tag then
      table.insert(found, child:Clone())
    end
    child:MoveNext()
  end
  return found
end

local function recordOf(ptr)
  local record = fhNewItemPtr()
  record:MoveToRecordItem(ptr)
  return record
end

local function personDescriptor(ptr)
  return { id = fhGetRecordId(ptr), qualifiedId = fhGetQualifiedRecordId(ptr), text = fhGetDisplayText(ptr) }
end

-- The people a fact is about: the owning Individual, or both spouses of the owning Family.
local function principalsOf(owner)
  if fhGetTag(owner) == "INDI" then
    return { owner:Clone() }
  end
  local principals = {}
  for _, tag in ipairs({ "HUSB", "WIFE" }) do
    for _, link in ipairs(childrenWithTag(owner, tag)) do
      local target = fhGetValueAsLink(link)
      if target and target:IsNotNull() then
        table.insert(principals, target)
      end
    end
  end
  return principals
end

local function isSpouseOf(familyPtr, personQualifiedId)
  for _, principal in ipairs(principalsOf(familyPtr)) do
    if fhGetQualifiedRecordId(principal) == personQualifiedId then
      return true
    end
  end
  return false
end

local function noteTexts(ptr)
  local notes = {}
  for _, note in ipairs(childrenWithTag(ptr, "NOTE2")) do
    table.insert(notes, { text = fhGetValueAsRichText(note):GetPlainText() })
  end
  for _, link in ipairs(childrenWithTag(ptr, "NOTE")) do
    local record = fhGetValueAsLink(link)
    if record and record:IsNotNull() then
      local text = fhNewItemPtr()
      text:MoveTo(record, "~.TEXT")
      table.insert(notes, {
        qualifiedId = fhGetQualifiedRecordId(record),
        text = text:IsNotNull() and fhGetValueAsRichText(text):GetPlainText() or "",
      })
    end
  end
  return notes
end

local function citationsOf(fact)
  local citations = {}
  for _, link in ipairs(childrenWithTag(fact, "SOUR")) do
    local source = fhGetValueAsLink(link)
    if source and source:IsNotNull() then
      table.insert(citations, {
        qualifiedId = fhGetQualifiedRecordId(source),
        title = fhGetDisplayText(source),
        page = fhGetItemText(link, "~.PAGE"),
      })
    end
  end
  return citations
end

local function mediaOf(fact)
  local media = {}
  for _, link in ipairs(childrenWithTag(fact, "OBJE")) do
    local item = fhGetValueAsLink(link)
    if item and item:IsNotNull() then
      table.insert(media, { qualifiedId = fhGetQualifiedRecordId(item), name = fhGetDisplayText(item) })
    end
  end
  return media
end

-- Describes one fact-list item for subjectId, or returns nil when it must stay hidden:
-- an Excluded principal hides the whole entry; a Name Only principal leaves involvement,
-- role and names with no fact detail.
local function describeEntry(item, subjectId)
  local witnessLink = fhGetTag(item) == "_SHAR" and item or nil
  local fact = item
  if witnessLink then
    fact = fhNewItemPtr()
    fact:MoveToParentItem(witnessLink)
  end
  local owner = recordOf(fact)

  local principals = principalsOf(owner)
  local detailVisible = true
  for _, principal in ipairs(principals) do
    local level = familyHelper.recordVisibility(principal)
    if level == "exclude" then
      return nil
    elseif level == "nameOnly" then
      detailVisible = false
    end
  end

  local involvement
  if witnessLink then
    involvement = "witness"
  elseif fhGetQualifiedRecordId(owner) == subjectId then
    involvement = "own"
  elseif fhGetTag(owner) == "FAM" and isSpouseOf(owner, subjectId) then
    involvement = "family"
  else
    involvement = "timeline"
  end

  local entry = { involvement = involvement, owner = fhGetQualifiedRecordId(owner), principals = {} }
  for i, principal in ipairs(principals) do
    entry.principals[i] = personDescriptor(principal)
  end
  if witnessLink then
    entry.role = fhGetItemText(witnessLink, "~.ROLE")
  end
  if not detailVisible then
    return entry
  end

  entry.tag = fhGetTag(fact)
  entry.text = fhGetDisplayText(fact)
  entry.date = fhGetItemText(fact, "~.DATE")
  entry.place = fhGetItemText(fact, "~.PLAC")
  entry.notes = noteTexts(fact)
  entry.citations = citationsOf(fact)
  entry.media = mediaOf(fact)
  if witnessLink then
    entry.participantNotes = noteTexts(witnessLink)
  end
  return entry
end

-- personEventsHelper.getPersonEvents(ptrIndividual, opts)
-- ptrIndividual: live pointer or qualified id string for an Individual record. Returns, in
-- chronological order, one entry per event the person is recorded as involved in:
-- involvement "own" (a Fact on their record), "family" (a Fact on a Family they are a
-- spouse of), "timeline" (a close relative's Fact, opts.timeline only) or "witness" (a
-- linked participant on a Shared Fact owned by someone else, with its ROLE).
--
-- An entry is { involvement, owner (qualified id of the owning record), principals (each
-- { id, qualifiedId, text }), role (witness only), tag, text, date, place, notes,
-- citations, media, participantNotes (witness only) }. A free-text witness and a name in a
-- note are never matched to the person.
--
-- opts (all optional booleans) pass straight to fhIndGetFactList: witness (true),
-- timeline (false), timelinePrefsOnly (false), narrative (false), resolveExclusions
-- (false), excludePrivate (false), excludeRejected (true). Unknown options raise.
--
-- Visibility: an Excluded subject raises; a Name Only subject has no events; a fact with
-- an Excluded principal is left out; one whose principal is Name Only keeps involvement,
-- role, owner and names and drops everything else.
function M.getPersonEvents(ptrIndividual, opts)
  ptrIndividual = familyHelper.resolvePointer(ptrIndividual)
  local problem = familyHelper.pointerProblem(ptrIndividual)
  if problem then
    error("getPersonEvents: ptrIndividual must point to an Individual record" .. problem)
  end
  if fhGetTag(ptrIndividual) ~= "INDI" then
    error("getPersonEvents: ptrIndividual must point to an Individual record, got a '" ..
      tostring(fhGetTag(ptrIndividual)) .. "' item")
  end
  local flags = factListFlags(opts)

  local level = familyHelper.recordVisibility(ptrIndividual)
  if level == "exclude" then
    error("getPersonEvents: this Individual is Excluded by the Session's Visibility settings. Don't retrieve this person's data by another route.")
  elseif level == "nameOnly" then
    return {}
  end

  local subjectId = fhGetQualifiedRecordId(ptrIndividual)
  local entries = {}
  for _, item in ipairs(fhIndGetFactList(ptrIndividual, table.unpack(flags))) do
    local entry = describeEntry(item, subjectId)
    if entry then
      table.insert(entries, entry)
    end
  end
  return entries
end

return M
