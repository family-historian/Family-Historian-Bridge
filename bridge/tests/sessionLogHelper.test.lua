-- Standalone tests for sessionLogHelper.lua. Run with: lua bridge/tests/sessionLogHelper.test.lua
-- No FH/socket dependency. Builds a small in-memory fake item-pointer/record-tree double,
-- scoped narrowly to only the globals sessionLogHelper.lua actually calls: fhCreateItem,
-- fhNewRichText (returning a fake RichText object with AddText/AddRecordLink), fhSetValueAsRichText,
-- fhGetQualifiedRecordId -- same style as sourceHelper.test.lua's fake tree, not reused
-- directly since sessionLogHelper.lua only ever creates records, never walks them.

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

fhCreateItem = function(tag)
  local node = { tag = tag, id = nextId }
  nextId = nextId + 1
  recordsByTag[tag] = recordsByTag[tag] or {}
  table.insert(recordsByTag[tag], node)
  local ptr = newPtr()
  ptr.list = recordsByTag[tag]
  ptr.index = #recordsByTag[tag]
  return ptr
end

-- Qualified record id prefixes, per fhGetQualifiedRecordId's own documented table (only
-- the two tags this test needs).
local QUALIFIED_PREFIX = { INDI = "I", _RNOT = "E" }

fhGetQualifiedRecordId = function(ptr)
  local node = currentNode(ptr)
  if not node then return "" end
  return (QUALIFIED_PREFIX[node.tag] or "?") .. tostring(node.id)
end

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
check(lastSave.node == noteNode, 'fhSetValueAsRichText is called on the new _RNOT record\'s own pointer')

local segments = lastSave.richText.segments
check(#segments == 3, 'one call produces a title segment, an entry-prefix segment, and one record link')

local titleSegment = segments[1]
check(titleSegment.kind == 'text' and contains(titleSegment.text, 'Claude session log'),
  'first segment is a title, timestamped with "Claude session log"')
check(titleSegment.rich == false, 'title text is added as plain (non-FTF) text')

local firstLink = segments[3]
check(firstLink.kind == 'reclink', 'the record reference is a real record link, not plain text')
check(firstLink.node == currentNode(indiA), 'the record link points at the record passed to logActivity')
check(firstLink.display == 'I' .. tostring(currentNode(indiA).id),
  'the record link\'s display label is the record\'s qualified id (fhGetQualifiedRecordId)')

------------------------------------------------------------------
-- Second call (same simulated Session): appends to the SAME note
------------------------------------------------------------------

sessionLogHelper.logActivity(indiB, "fact added Birth")

check(#(recordsByTag["_RNOT"] or {}) == rnotBefore + 1, 'second call creates no additional _RNOT record')

local lastSave2 = setValueCalls[#setValueCalls]
check(lastSave2.node == noteNode, 'second call still saves onto the same _RNOT record')

local segments2 = lastSave2.richText.segments
check(#segments2 == 6, 'second call appends a further entry rather than replacing the buffer')

-- Earlier entry untouched.
check(segments2[1].text == segments[1].text, 'the first entry\'s title text is unchanged after the second call')
check(segments2[3].kind == 'reclink' and segments2[3].node == firstLink.node and segments2[3].display == firstLink.display,
  'the first entry\'s record link is unchanged after the second call')

local secondLink = segments2[6]
check(secondLink.kind == 'reclink', 'the second entry\'s record reference is also a real record link')
check(secondLink.node == currentNode(indiB), 'the second record link points at the second record passed to logActivity')
check(secondLink.display == 'I' .. tostring(currentNode(indiB).id),
  'the second record link\'s display label is that record\'s own qualified id')

local actionText = segments2[5]
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

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
