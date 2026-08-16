-- Standalone tests for sessionLogHelper.lua. Run with: lua bridge/tests/sessionLogHelper.test.lua
-- No FH/socket dependency. Builds a small in-memory fake item-pointer/record-tree double,
-- scoped narrowly to only the globals sessionLogHelper.lua actually calls: fhCreateItem,
-- fhNewItemPtr (and its MoveTo method, to reach a _RNOT record's auto-created TEXT
-- subfield), fhNewRichText (returning a fake RichText object with AddText/AddRecordLink),
-- fhSetValueAsRichText -- same style as sourceHelper.test.lua's fake tree, not reused
-- directly since sessionLogHelper.lua only ever creates records, never walks existing ones.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

local function contains(haystack, needle)
  return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
end

------------------------------------------------------------------
-- Fake tree: records grouped by tag, each node a plain table with { tag, id }.
------------------------------------------------------------------

local recordsByTag
local nextId

local function resetTree()
  recordsByTag = {}
  nextId = 1
end

-- Write-result failure injection (issue #111, docs/adr/0028): set true immediately
-- before the one call a fixture wants to fail; self-resets after firing once.
local forceNextCreateFailure = false
local forceNextWriteFailure = false

local PtrMethods = {}
PtrMethods.__index = PtrMethods

local function newPtr()
  return setmetatable({ list = nil, index = nil }, PtrMethods)
end

local function currentNode(ptr)
  return ptr.list and ptr.list[ptr.index]
end

-- Real FH auto-creates a _RNOT record's one mandatory TEXT subfield as part of
-- fhCreateItem('_RNOT') itself (confirmed live 2026-08-01: fhSetValueAsRichText on the
-- record's own top-level pointer silently returns false and writes nothing -- the value
-- only ever lived on this child). Modelled here as a node.textNode set at creation time,
-- reached via ptr:MoveTo(notePtr, '~.TEXT') the same way sessionLogHelper.lua does.
fhCreateItem = function(tag)
  if forceNextCreateFailure then
    forceNextCreateFailure = false
    -- An unpositioned fake pointer: currentNode(ptr) is nil, so :IsNull() is true --
    -- the same shape real FH's own NULL-pointer create failure has.
    return newPtr()
  end
  local node = { tag = tag, id = nextId }
  nextId = nextId + 1
  if tag == '_RNOT' then
    node.textNode = { tag = 'TEXT', id = nextId }
    nextId = nextId + 1
  end
  recordsByTag[tag] = recordsByTag[tag] or {}
  table.insert(recordsByTag[tag], node)
  local ptr = newPtr()
  ptr.list = recordsByTag[tag]
  ptr.index = #recordsByTag[tag]
  return ptr
end

function PtrMethods:IsNull()
  return currentNode(self) == nil
end

function PtrMethods:MoveTo(otherPtr, dataRef)
  local node = currentNode(otherPtr)
  if dataRef == '~.TEXT' and node and node.textNode then
    self.list = { node.textNode }
    self.index = 1
  else
    self.list = nil
    self.index = nil
  end
end


-- ptrRecord must be a top-level record, not a Fact/sub-item (issue #110 follow-up):
-- fhHasParentItem is FH's own documented way to tell them apart ("record items do not
-- have parent items, but all other items (i.e. field items) do"). Nodes get an optional
-- .parent field for this -- fhCreateItem above never sets one (every node it creates is
-- top-level), so a "has a parent" fixture is built directly in the test that needs one.
fhHasParentItem = function(ptr)
  local node = currentNode(ptr)
  return node ~= nil and node.parent ~= nil
end

fhGetTag = function(ptr)
  local node = currentNode(ptr)
  return node and node.tag
end
fhNewItemPtr = newPtr

------------------------------------------------------------------
-- Fake RichText object: records an ordered list of segments, either plain-text
-- (AddText) or a real record-link entry (AddRecordLink) that stores the actual target
-- node -- not a string containing "<rec=" -- so tests can tell a genuine link apart from
-- text that merely looks like one.
------------------------------------------------------------------

local RichTextMethods = {}
RichTextMethods.__index = RichTextMethods

local function newRichText()
  return setmetatable({ segments = {} }, RichTextMethods)
end

function RichTextMethods:AddText(text, bRich)
  table.insert(self.segments, { kind = 'text', text = text, rich = bRich })
  return true
end

function RichTextMethods:AddRecordLink(ptr, displayText)
  table.insert(self.segments, { kind = 'reclink', node = currentNode(ptr), display = displayText })
  return true
end

fhNewRichText = newRichText

local setValueCalls = {}
fhSetValueAsRichText = function(ptr, richTextObj)
  table.insert(setValueCalls, { node = currentNode(ptr), richText = richTextObj })
  if forceNextWriteFailure then
    forceNextWriteFailure = false
    return false
  end
  return true
end

------------------------------------------------------------------
-- Fixtures
------------------------------------------------------------------

resetTree()

local indiA = fhCreateItem("INDI")
local indiB = fhCreateItem("INDI")

local sessionLogHelper = require('sessionLogHelper')

------------------------------------------------------------------
-- First call: creates a new, timestamped Research Note with one log entry
------------------------------------------------------------------

local rnotBefore = #(recordsByTag["_RNOT"] or {})
sessionLogHelper.logActivity(indiA, "created")

check(#(recordsByTag["_RNOT"] or {}) == rnotBefore + 1, 'first call creates exactly one new _RNOT record')

local noteNode = recordsByTag["_RNOT"][#recordsByTag["_RNOT"]]
local lastSave = setValueCalls[#setValueCalls]
check(lastSave.node == noteNode.textNode, 'fhSetValueAsRichText is called on the new _RNOT record\'s TEXT subfield, not the record\'s own pointer')

local segments = lastSave.richText.segments
check(#segments == 9, 'one call produces the Title:/Type:/Status:/Date: header (6 segments, since Title: needs its own open/text/close markup split) plus a bullet marker, an entry-prefix segment, and one record link')

check(segments[1].kind == 'text' and segments[1].text == '<b><fs="+2">' and segments[1].rich == true,
  'Title: opens with bold + a +2pt size bump, as real FTF markup (issue #79, kept through issue #112)')

local titleSegment = segments[2]
check(titleSegment.kind == 'text' and contains(titleSegment.text, 'Title: Claude session log'),
  'second segment is the Title: line, labelled and timestamped (issue #112)')
check(titleSegment.rich == false, 'the Title: line itself is added as plain (auto-escaped) text, separate from the markup segments')

check(segments[3].kind == 'text' and segments[3].text == '</fs></b>\n' and segments[3].rich == true,
  'Title: closes bold/size and ends its own paragraph (issue #112 -- the blank-paragraph gap moved to after Date:, since the old intro line is gone)')

check(segments[4].kind == 'text' and segments[4].text == 'Type: mcp-log\n' and segments[4].rich == false,
  'Type: is a fixed constant, plain (non-FTF-markup) font (issue #112)')

check(segments[5].kind == 'text' and segments[5].text == 'Status: closed\n' and segments[5].rich == false,
  'Status: is a fixed constant, plain font (issue #112)')

check(segments[6].kind == 'text' and segments[6].rich == false and segments[6].text:match('^Date: %d%d %a%a%a %d%d%d%d\n\n$') ~= nil,
  'Date: uses its own human-scannable date-only format, and its trailing blank line separates the header from the first entry (issue #112)')

check(segments[7].kind == 'text' and segments[7].text == '* ' and segments[7].rich == true,
  'the entry starts a new bulleted FTF paragraph (issue #79)')

local firstLink = segments[9]
check(firstLink.kind == 'reclink', 'the record reference is a real record link, not plain text')
check(firstLink.node == currentNode(indiA), 'the record link points at the record passed to logActivity')
check(firstLink.display == nil,
  'AddRecordLink is called with no display-text argument, so FH treats the link as "automatic" -- showing the record\'s own live-updating display name rather than a name/id frozen at log time')

------------------------------------------------------------------
-- Second call (same simulated Session): appends to the SAME note
------------------------------------------------------------------

sessionLogHelper.logActivity(indiB, "fact added Birth")

check(#(recordsByTag["_RNOT"] or {}) == rnotBefore + 1, 'second call creates no additional _RNOT record')

local lastSave2 = setValueCalls[#setValueCalls]
check(lastSave2.node == noteNode.textNode, 'second call still saves onto the same _RNOT record\'s TEXT subfield')

local segments2 = lastSave2.richText.segments
check(#segments2 == 13, 'second call appends a further bulleted entry (separator, bullet, prefix, link) rather than replacing the buffer')

-- Earlier entry untouched.
check(segments2[2].text == segments[2].text, 'the Title: line is unchanged after the second call')
check(segments2[9].kind == 'reclink' and segments2[9].node == firstLink.node and segments2[9].display == firstLink.display,
  'the first entry\'s record link is unchanged after the second call')

check(segments2[10].kind == 'text' and segments2[10].text == '\n' and segments2[10].rich == false,
  'a blank-line separator precedes the second entry, as before')
check(segments2[11].kind == 'text' and segments2[11].text == '* ' and segments2[11].rich == true,
  'the second entry also starts its own bulleted FTF paragraph')

local secondLink = segments2[13]
check(secondLink.kind == 'reclink', 'the second entry\'s record reference is also a real record link')
check(secondLink.node == currentNode(indiB), 'the second record link points at the second record passed to logActivity')
check(secondLink.display == nil, 'the second record link is also "automatic" (no display-text argument)')

local actionText = segments2[12]
check(actionText.kind == 'text' and contains(actionText.text, 'fact added Birth'),
  'the second entry\'s action text is included in the appended segment')

------------------------------------------------------------------
-- A fresh module load (simulating a new Session) starts a new note on its next call
------------------------------------------------------------------

package.loaded['sessionLogHelper'] = nil
local freshSessionLogHelper = require('sessionLogHelper')

local rnotBeforeFresh = #(recordsByTag["_RNOT"] or {})
local indiC = fhCreateItem("INDI")
freshSessionLogHelper.logActivity(indiC, "created")

check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeFresh + 1,
  'a fresh module load creates a new _RNOT record on its first call, rather than reusing the prior Session\'s')

local freshNoteNode = recordsByTag["_RNOT"][#recordsByTag["_RNOT"]]
check(freshNoteNode ~= noteNode, 'the fresh Session\'s note is a different record from the previous Session\'s')

------------------------------------------------------------------
-- Optional media detail (issue #39): appends an indented (">") #ToDo sub-line as its own
-- FTF paragraph under the entry, opt-in per call. Exact no-location wording is pinned to
-- the 2026-08-01 grilling session's own Nellie Record birth-certificate example from issue
-- #23/#39; the leading-space indent from that session was replaced with a real FTF indent
-- marker in the 2026-08-08 grilling session on issue #79.
------------------------------------------------------------------

local indiD = fhCreateItem("INDI")
local lastSaveBeforeMedia = setValueCalls[#setValueCalls]
local segmentCountBeforeMedia = #lastSaveBeforeMedia.richText.segments

freshSessionLogHelper.logActivity(indiD, "fact added Birth", { name = "bc-nellie.jpg" })

check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeFresh + 1, 'a call with a media detail creates no additional _RNOT record')

local lastSaveMedia = setValueCalls[#setValueCalls]
check(lastSaveMedia.node == freshNoteNode.textNode, 'a call with a media detail still saves onto the same Session note\'s TEXT subfield')

local segmentsMedia = lastSaveMedia.richText.segments
check(#segmentsMedia == segmentCountBeforeMedia + 7,
  'a media detail appends its own separator/indent-marker/sub-line-text three segments beyond the usual separator/bullet/prefix/link four')

check(segmentsMedia[#segmentsMedia - 2].kind == 'text' and segmentsMedia[#segmentsMedia - 2].text == '\n' and segmentsMedia[#segmentsMedia - 2].rich == false,
  'the media sub-line starts its own paragraph with a blank-line separator')
check(segmentsMedia[#segmentsMedia - 1].kind == 'text' and segmentsMedia[#segmentsMedia - 1].text == '>' and segmentsMedia[#segmentsMedia - 1].rich == true,
  'the media sub-line paragraph opens with a real FTF indent marker (issue #79), not literal leading spaces')

local sublineNoLocation = segmentsMedia[#segmentsMedia]
check(sublineNoLocation.kind == 'text' and sublineNoLocation.rich == false, 'the media sub-line text itself is added as plain (auto-escaped) text')
check(sublineNoLocation.text == '[ ] #ToDo Media to be added bc-nellie.jpg',
  'the media sub-line (no location) matches the grilling session\'s Nellie Record wording, now without the old leading-space indent')

------------------------------------------------------------------
-- Media detail with a location: the location appears in the sub-line too.
------------------------------------------------------------------

local indiE = fhCreateItem("INDI")
local segmentCountBeforeLocation = #segmentsMedia

freshSessionLogHelper.logActivity(indiE, "fact added Marriage", { name = "cert.jpg", location = "family archive box" })

local lastSaveLocation = setValueCalls[#setValueCalls]
local segmentsLocation = lastSaveLocation.richText.segments
check(#segmentsLocation == segmentCountBeforeLocation + 7,
  'a media detail with a location also appends exactly one separator/indent-marker/sub-line-text trio')

local sublineWithLocation = segmentsLocation[#segmentsLocation]
check(sublineWithLocation.text == '[ ] #ToDo Media to be added cert.jpg (family archive box)',
  'the media sub-line includes the location when one is given')

------------------------------------------------------------------
-- No media detail: strictly opt-in, no sub-line appended (matches the blocking ticket's
-- own two-argument calls).
------------------------------------------------------------------

local indiF = fhCreateItem("INDI")
local segmentCountBeforeNoMedia = #segmentsLocation

freshSessionLogHelper.logActivity(indiF, "created")

local lastSaveNoMedia = setValueCalls[#setValueCalls]
local segmentsNoMedia = lastSaveNoMedia.richText.segments
check(#segmentsNoMedia == segmentCountBeforeNoMedia + 4,
  'calling logActivity without a media detail appends no sub-line (opt-in per call)')

------------------------------------------------------------------
-- A media table missing "name" errors before touching the buffer, rather than leaving a
-- stray, never-flushed entry behind for the next successful call to inherit.
------------------------------------------------------------------

local indiG = fhCreateItem("INDI")
local segmentCountBeforeBadMedia = #segmentsNoMedia
local setValueCallCountBeforeBadMedia = #setValueCalls

local ok = pcall(freshSessionLogHelper.logActivity, indiG, "created", { location = "family archive box" })

check(ok == false, 'a media table without a name raises an error rather than silently proceeding')
check(#setValueCalls == setValueCallCountBeforeBadMedia, 'the failed call never saved anything to the note')

freshSessionLogHelper.logActivity(indiG, "created")
local lastSaveAfterBadMedia = setValueCalls[#setValueCalls]
check(#lastSaveAfterBadMedia.richText.segments == segmentCountBeforeBadMedia + 4,
  'the buffer is unaffected by the earlier failed call -- no stray entry was left behind')

------------------------------------------------------------------
-- ptrRecord/action are validated up front too, the same way media.name is (issue #95, from
-- a live run_lua call that passed a nil ptrRecord and only found out via the AddRecordLink
-- crash further down -- see sessionLogHelper.lua's own comment on M.logActivity for the full
-- rollback/Session-death chain that a caught-early error here now avoids). Each case here
-- must fail before fhCreateItem/the buffer are ever touched, not just fail eventually.
------------------------------------------------------------------

local rnotBeforeInvalid = #(recordsByTag["_RNOT"] or {})
local setValueCallCountBeforeInvalid = #setValueCalls

local okNilPtr, errNilPtr = pcall(freshSessionLogHelper.logActivity, nil, "created")
check(okNilPtr == false, 'a nil ptrRecord raises an error rather than proceeding')
check(contains(errNilPtr, "ptrRecord"), 'the nil-ptrRecord error names ptrRecord specifically')

local nullPtr = fhNewItemPtr()
local okNullPtr = pcall(freshSessionLogHelper.logActivity, nullPtr, "created")
check(okNullPtr == false, 'a non-nil but IsNull() ptrRecord also raises an error rather than proceeding')

local okStringPtr, errStringPtr = pcall(freshSessionLogHelper.logActivity,
  "E40: ticked items rec=S29/S31/S35", "created")
check(okStringPtr == false,
  'a string ptrRecord (issue #110: the whole action-description string landed in ptrRecord\'s slot, one arg short) raises an error rather than a raw Lua crash')
check(contains(errStringPtr, "ptrRecord"),
  'the string-ptrRecord error names ptrRecord specifically, not a raw method-missing crash')
check(contains(errStringPtr, "string"), 'the error names the type actually given')
check(not contains(errStringPtr, "IsNull"),
  'the error is logActivity\'s own message, not a raw "attempt to call ... IsNull" crash')

local factNode = { tag = 'BIRT', id = 99999, parent = indiG }
local factPtr = newPtr()
factPtr.list = { factNode }
factPtr.index = 1

local okFactPtr, errFactPtr = pcall(freshSessionLogHelper.logActivity, factPtr, "created")
check(okFactPtr == false,
  'a Fact/sub-item ptrRecord (not a top-level record) raises an error rather than silently creating a misleading record link')
check(contains(errFactPtr, "ptrRecord"), 'the error names ptrRecord specifically')
check(contains(errFactPtr, "BIRT"), 'the error names the actual tag found, same style as getFamilyGroup\'s wrong-record-type error')

local okNilAction, errNilAction = pcall(freshSessionLogHelper.logActivity, indiG, nil)
check(okNilAction == false, 'a nil action raises an error rather than proceeding')
check(contains(errNilAction, "action"), 'the nil-action error names action specifically')

local okEmptyAction = pcall(freshSessionLogHelper.logActivity, indiG, "")
check(okEmptyAction == false, 'an empty-string action also raises an error rather than proceeding')

check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeInvalid,
  'none of the six invalid calls above created a _RNOT record')
check(#setValueCalls == setValueCallCountBeforeInvalid,
  'none of the six invalid calls above wrote anything to the note -- caught before fhCreateItem/the buffer, not just eventually')

------------------------------------------------------------------
-- validateLogActivity (issue #97): the pure validation half of logActivity, exported so
-- sandbox.lua can run it untracked before arming the write tracker. Same success/failure
-- behavior as logActivity's own up-front checks, but never touches the tree -- not even on
-- success (that's the rest of logActivity's job).
------------------------------------------------------------------

local rnotBeforeValidateOnly = #(recordsByTag["_RNOT"] or {})
local setValueCallCountBeforeValidateOnly = #setValueCalls

local okValidateOnly = pcall(freshSessionLogHelper.validateLogActivity, indiG, "created")
check(okValidateOnly == true, 'validateLogActivity succeeds silently on valid input')
check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeValidateOnly, 'validateLogActivity never creates a _RNOT record, even on success')
check(#setValueCalls == setValueCallCountBeforeValidateOnly, 'validateLogActivity never writes to the buffer, even on success')

local okValidateOnlyNilPtr, errValidateOnlyNilPtr = pcall(freshSessionLogHelper.validateLogActivity, nil, "created")
check(okValidateOnlyNilPtr == false, 'validateLogActivity rejects a nil ptrRecord, same as logActivity')
check(contains(errValidateOnlyNilPtr, "ptrRecord"), 'the rejection names ptrRecord specifically')

local okValidateOnlyBadType, errValidateOnlyBadType = pcall(freshSessionLogHelper.validateLogActivity, 42, "created")
check(okValidateOnlyBadType == false, 'validateLogActivity rejects a wrong-typed (number) ptrRecord too, same as logActivity')
check(contains(errValidateOnlyBadType, "number") and contains(errValidateOnlyBadType, "42"),
  'the rejection names both the type and the value actually given')

local okValidateOnlyFactPtr, errValidateOnlyFactPtr = pcall(freshSessionLogHelper.validateLogActivity, factPtr, "created")
check(okValidateOnlyFactPtr == false, 'validateLogActivity rejects a Fact/sub-item ptrRecord too, same as logActivity')
check(contains(errValidateOnlyFactPtr, "BIRT"), 'the rejection names the actual tag found')

------------------------------------------------------------------
-- Write-result checks (issue #111, docs/adr/0028): a bOK=false/NULL-pointer failure from
-- fhSetValueAsRichText/fhCreateItem now raises via familyHelper.checkWrite/checkCreated
-- instead of being silently discarded. checkWrite/checkCreated themselves are unit-tested
-- directly in familyHelper.test.lua -- this just proves logActivity is wired to them, and
-- that a failed note-create doesn't corrupt the module's persistent notePtr state for the
-- rest of the Session.
------------------------------------------------------------------

package.loaded['sessionLogHelper'] = nil
local writeCheckSessionLogHelper = require('sessionLogHelper')
local indiWriteCheck = fhCreateItem("INDI")

forceNextCreateFailure = true
local okNoteCreate, errNoteCreate = pcall(writeCheckSessionLogHelper.logActivity, indiWriteCheck, "created")
check(okNoteCreate == false, 'logActivity raises when fhCreateItem("_RNOT") itself fails')
check(contains(errNoteCreate, "logActivity") and contains(errNoteCreate, "_RNOT"),
  'the note-create error names the function and what failed to create')

local rnotCountBeforeRetry = #(recordsByTag["_RNOT"] or {})
writeCheckSessionLogHelper.logActivity(indiWriteCheck, "created")
check(#(recordsByTag["_RNOT"] or {}) == rnotCountBeforeRetry + 1,
  'a later call after a failed note-create still creates a fresh _RNOT record, not stuck reusing the broken one')

forceNextWriteFailure = true
local okSave, errSave = pcall(writeCheckSessionLogHelper.logActivity, indiWriteCheck, "fact added Birth")
check(okSave == false, 'logActivity raises when the entry save (fhSetValueAsRichText) fails')
check(contains(errSave, "logActivity"), 'the save-failure error names the function')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
