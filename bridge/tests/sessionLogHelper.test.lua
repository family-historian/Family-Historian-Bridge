-- Standalone tests for sessionLogHelper.lua. Run with: lua bridge/tests/sessionLogHelper.test.lua
-- No FH/socket dependency. Builds a small in-memory fake item-pointer/record-tree double,
-- scoped narrowly to only the globals sessionLogHelper.lua actually calls: fhCreateItem,
-- fhNewItemPtr (and its MoveTo method, to reach a _RNOT record's auto-created TEXT
-- subfield), fhNewRichText (returning a fake RichText object with AddText/AddRecordLink),
-- fhSetValueAsRichText -- same style as sourceHelper.test.lua's fake tree, not reused
-- directly since sessionLogHelper.lua only ever creates records, never walks existing ones.

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../?.lua'

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
check(#segments == 7, 'one call produces bold/size heading markup, the heading text, the static intro paragraph, a bullet marker, an entry-prefix segment, and one record link')

check(segments[1].kind == 'text' and segments[1].text == '<b><fs="+2">' and segments[1].rich == true,
  'heading opens with bold + a +2pt size bump, as real FTF markup (issue #79)')

local titleSegment = segments[2]
check(titleSegment.kind == 'text' and contains(titleSegment.text, 'Claude session log'),
  'second segment is the heading text, timestamped with "Claude session log"')
check(titleSegment.rich == false, 'heading text itself is added as plain (auto-escaped) text, separate from the markup segments')

check(segments[3].kind == 'text' and segments[3].text == '</fs></b>\n\n' and segments[3].rich == true,
  'heading closes bold/size and leaves a blank paragraph before the intro line (issue #79 follow-up)')

check(segments[4].kind == 'text' and segments[4].text == 'The following updates were applied to the project:\n' and segments[4].rich == false,
  'a static intro paragraph follows the heading, written once, in default (non-FTF-markup) font (issue #79)')

check(segments[5].kind == 'text' and segments[5].text == '* ' and segments[5].rich == true,
  'the entry starts a new bulleted FTF paragraph (issue #79)')

local firstLink = segments[7]
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
check(#segments2 == 11, 'second call appends a further bulleted entry (separator, bullet, prefix, link) rather than replacing the buffer')

-- Earlier entry untouched.
check(segments2[2].text == segments[2].text, 'the heading text is unchanged after the second call')
check(segments2[7].kind == 'reclink' and segments2[7].node == firstLink.node and segments2[7].display == firstLink.display,
  'the first entry\'s record link is unchanged after the second call')

check(segments2[8].kind == 'text' and segments2[8].text == '\n' and segments2[8].rich == false,
  'a blank-line separator precedes the second entry, as before')
check(segments2[9].kind == 'text' and segments2[9].text == '* ' and segments2[9].rich == true,
  'the second entry also starts its own bulleted FTF paragraph')

local secondLink = segments2[11]
check(secondLink.kind == 'reclink', 'the second entry\'s record reference is also a real record link')
check(secondLink.node == currentNode(indiB), 'the second record link points at the second record passed to logActivity')
check(secondLink.display == nil, 'the second record link is also "automatic" (no display-text argument)')

local actionText = segments2[10]
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

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
