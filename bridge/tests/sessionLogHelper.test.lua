-- Standalone tests for sessionLogHelper.lua. Run with: lua bridge/tests/sessionLogHelper.test.lua
-- No FH/socket dependency. Builds a small in-memory fake item-pointer/record-tree double,
-- scoped narrowly to only the globals sessionLogHelper.lua actually calls: fhCreateItem,
-- fhNewItemPtr (and its MoveTo method, to reach a _RNOT record's auto-created TEXT
-- subfield), fhNewRichText (returning a fake RichText object with AddText/AddRecordLink),
-- fhSetValueAsRichText -- same style as sourceHelper.test.lua's fake tree, not reused
-- directly since sessionLogHelper.lua only ever creates records, never walks existing ones.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'

local t = require('testHelpers').new()
local check, contains = t.check, t.contains

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

function PtrMethods:IsNotNull()
  return currentNode(self) ~= nil
end

-- Minimal child-item walk, needed only for familyHelper.recordVisibility's _FLGS walk
-- (issue #141) -- a node's own .children array (nil/empty for every pre-#141 fixture) is
-- reused as the pointed-to list, same as factHelper.test.lua/sourceHelper.test.lua's own.
function PtrMethods:MoveToFirstChildItem(parentPtr)
  local node = currentNode(parentPtr)
  self.list = (node and node.children) or {}
  self.index = 1
end

function PtrMethods:MoveNext()
  self.index = self.index + 1
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

-- Needed for familyHelper.resolvePointer's qualified-id-string resolution (issue #114) --
-- same fake as factHelper.test.lua's own MoveToRecordById.
function PtrMethods:MoveToRecordById(tag, id)
  local list = recordsByTag[tag] or {}
  for i, node in ipairs(list) do
    if node.id == id then
      self.list = list
      self.index = i
      return
    end
  end
  self.list = list
  self.index = #list + 1
end


-- A record item has no .parent; a Fact/field/citation item does (fhHasParentItem is FH's
-- own documented way to tell them apart: "record items do not have parent items, but all
-- other items (i.e. field items) do"). Nodes get an optional .parent field for this --
-- fhCreateItem above never sets one (every node it creates is top-level), so a "has a
-- parent" fixture is built directly in the test that needs one.
fhHasParentItem = function(ptr)
  local node = currentNode(ptr)
  return node ~= nil and node.parent ~= nil
end

fhGetTag = function(ptr)
  local node = currentNode(ptr)
  return node and node.tag
end
fhNewItemPtr = newPtr

-- Needed for validateLogActivity's auto-correct climb (issue #117): moves self to point at
-- ptrRef's owning record, walking the .parent chain as far as needed (a Fact, or something
-- nested even deeper under it) the same way real MoveToRecordItem climbs regardless of
-- depth. If the climb doesn't land on a node this fake tree actually has on record (the
-- defensive-backstop test's orphan fixture), self ends up unpositioned/IsNull(), the same
-- shape real FH's own "couldn't resolve" case has.
function PtrMethods:MoveToRecordItem(ptrRef)
  local node = currentNode(ptrRef)
  while node and node.parent do
    node = node.parent
  end
  if node then
    local list = recordsByTag[node.tag] or {}
    for i, n in ipairs(list) do
      if n == node then
        self.list = list
        self.index = i
        return
      end
    end
  end
  self.list = nil
  self.index = nil
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
  local ok = not forceNextWriteFailure
  if forceNextWriteFailure then
    forceNextWriteFailure = false
  end
  -- Snapshots the segments seen at this exact call, rather than keeping the same mutable
  -- richTextObj reference -- otherwise a later mutation of the caller's still-live buffer
  -- (e.g. a subsequent, unsaved append) would silently bleed backward into what this
  -- "already saved" call recorded, which real FH's own tree-copy-on-write semantics never
  -- allow.
  local snapshot = newRichText()
  for _, seg in ipairs(richTextObj.segments) do
    table.insert(snapshot.segments, seg)
  end
  table.insert(setValueCalls, { node = currentNode(ptr), richText = snapshot, ok = ok })
  return ok
end

-- Models a fresh fetch of a node's on-disk RichText value (issue #133's
-- recoverAfterRollback): returns a new RichText object seeded from that node's most
-- recent *successful* fhSetValueAsRichText save (a failed save never reached disk, so it
-- must not be resurrected by a later fetch) -- a fresh object, not the same Lua table a
-- caller's buffer local already holds, same "independent object" contract the real fetch
-- has.
fhGetValueAsRichText = function(ptr)
  local node = currentNode(ptr)
  for i = #setValueCalls, 1, -1 do
    if setValueCalls[i].node == node and setValueCalls[i].ok then
      local fetched = newRichText()
      for _, seg in ipairs(setValueCalls[i].richText.segments) do
        table.insert(fetched.segments, seg)
      end
      return fetched
    end
  end
  return newRichText()
end

------------------------------------------------------------------
-- Fixtures
------------------------------------------------------------------

resetTree()

local indiA = fhCreateItem("INDI")
local indiB = fhCreateItem("INDI")

local sessionLogHelper = require('sessionLogHelper')
local familyHelper = require('familyHelper')

-- Adds a Record Flag child (e.g. "__PRIVATE"/"__LIVING") under indiPtr's _FLGS item,
-- creating _FLGS on first use -- mirrors familyHelper.test.lua's own addFlag (issue #141).
local function addFlag(indiPtr, flagTag)
  local node = currentNode(indiPtr)
  node.children = node.children or {}
  local flgs
  for _, c in ipairs(node.children) do
    if c.tag == "_FLGS" then flgs = c end
  end
  if not flgs then
    flgs = { tag = "_FLGS", children = {} }
    table.insert(node.children, flgs)
  end
  table.insert(flgs.children, { tag = flagTag, children = {} })
end

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
check(#segments == 7, 'one call produces the Title:/Type:/Status:/Date: header (4 segments -- bold-open, Title: text, bold-close, and one merged Type:/Status:/Date: paragraph) plus a bullet marker, an entry-prefix segment, and one record link')

check(segments[1].kind == 'text' and segments[1].text == '<b><fs="+2">' and segments[1].rich == true,
  'Title: opens with bold + a +2pt size bump, as real FTF markup (issue #79, kept through issue #112)')

local titleSegment = segments[2]
check(titleSegment.kind == 'text' and contains(titleSegment.text, 'Title: Claude session log'),
  'second segment is the Title: line, labelled and timestamped (issue #112)')
check(titleSegment.rich == false, 'the Title: line itself is added as plain (auto-escaped) text, separate from the markup segments')

check(segments[3].kind == 'text' and segments[3].text == '</fs></b>\n' and segments[3].rich == true,
  'Title: closes bold/size and ends its own paragraph (issue #112 -- the blank-paragraph gap moved to after Date:, since the old intro line is gone)')

check(segments[4].kind == 'text' and segments[4].rich == false
  and segments[4].text:match('^Type: mcp%-log\nStatus: closed\nDate: %d%d %a%a%a %d%d%d%d\n\n$') ~= nil,
  'Type:/Status:/Date: are written as one plain (non-FTF-markup) paragraph block -- Type/Status are fixed constants, Date: uses its own human-scannable date-only format, and the trailing blank line separates the header from the first entry (issue #112)')

check(segments[5].kind == 'text' and segments[5].text == '* ' and segments[5].rich == true,
  'the entry starts a new bulleted FTF paragraph (issue #79)')

-- The record link is always the entry's last segment (nothing follows AddRecordLink when
-- there's no media detail), so indexing off #segments needs no header-size-dependent offset.
local firstLink = segments[#segments]
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

-- Earlier entry untouched. segments/segments2 are the same underlying (mutated-in-place)
-- table, so re-checking firstLink's own fields directly proves the first entry's slot
-- wasn't touched, with no need to re-derive its index into the now-longer segments2.
check(segments2[2].text == segments[2].text, 'the Title: line is unchanged after the second call')
check(firstLink.kind == 'reclink' and firstLink.node == currentNode(indiA) and firstLink.display == nil,
  'the first entry\'s record link is unchanged after the second call')

-- The second entry's four appended segments (separator, bullet, prefix, link) are always the
-- last four in the buffer, regardless of the header's own segment count.
check(segments2[#segments2 - 3].kind == 'text' and segments2[#segments2 - 3].text == '\n' and segments2[#segments2 - 3].rich == false,
  'a blank-line separator precedes the second entry, as before')
check(segments2[#segments2 - 2].kind == 'text' and segments2[#segments2 - 2].text == '* ' and segments2[#segments2 - 2].rich == true,
  'the second entry also starts its own bulleted FTF paragraph')

local actionText = segments2[#segments2 - 1]
check(actionText.kind == 'text' and contains(actionText.text, 'fact added Birth'),
  'the second entry\'s action text is included in the appended segment')

local secondLink = segments2[#segments2]
check(secondLink.kind == 'reclink', 'the second entry\'s record reference is also a real record link')
check(secondLink.node == currentNode(indiB), 'the second record link points at the second record passed to logActivity')
check(secondLink.display == nil, 'the second record link is also "automatic" (no display-text argument)')

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
-- Note: a Fact/sub-item ptrRecord is NOT one of these invalid cases (issue #117) -- see the
-- auto-correct section below, after this block.
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
  'a string ptrRecord that is not qualified-id-shaped (issue #110: the whole action-description string landed in ptrRecord\'s slot, one arg short) raises an error rather than a raw Lua crash')
check(contains(errStringPtr, "could not resolve qualified id"),
  'the error is familyHelper.resolveQualifiedId\'s own message (issue #114: ptrRecord now resolves through familyHelper.resolvePointer first, so a non-qualified-id-shaped string fails there, the same unwrapped-error convention getAllDetails/getFactsByTag/createFact already use)')
check(not contains(errStringPtr, "IsNull"),
  'the error is a named error(), not a raw "attempt to call ... IsNull" crash')

local okNilAction, errNilAction = pcall(freshSessionLogHelper.logActivity, indiG, nil)
check(okNilAction == false, 'a nil action raises an error rather than proceeding')
check(contains(errNilAction, "action"), 'the nil-action error names action specifically')

local okEmptyAction = pcall(freshSessionLogHelper.logActivity, indiG, "")
check(okEmptyAction == false, 'an empty-string action also raises an error rather than proceeding')

check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeInvalid,
  'none of the five invalid calls above created a _RNOT record')
check(#setValueCalls == setValueCallCountBeforeInvalid,
  'none of the five invalid calls above wrote anything to the note -- caught before fhCreateItem/the buffer, not just eventually')

------------------------------------------------------------------
-- ptrRecord may also be a Fact/sub-item pointer (issue #117, 2026-08-18 grilling session --
-- reverses issue #110's own decision to reject one): validateLogActivity now climbs to the
-- item's owning record via ptr:MoveToRecordItem(ptr) instead of erroring, so a caller's
-- targeting mistake on logActivity's own call -- reported live as the very last call of a
-- multi-step write -- no longer triggers ADR 0005's full write-then-error rollback and
-- undoes everything already written for what was really just a targeting mistake, not a
-- data mistake. The correction is silent: the record link lands on the owning record
-- exactly as if the caller had passed it directly; nothing in the note or return value
-- marks that a correction happened.
------------------------------------------------------------------

local factNode = { tag = 'BIRT', id = 99999, parent = currentNode(indiG) }
local factPtr = newPtr()
factPtr.list = { factNode }
factPtr.index = 1

local rnotBeforeFactPtr = #(recordsByTag["_RNOT"] or {})
freshSessionLogHelper.logActivity(factPtr, "created")
check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeFactPtr,
  'a Fact/sub-item ptrRecord no longer raises an error -- it appends to the same Session note as every other call in this block, creating no new _RNOT record')

local factPtrSave = setValueCalls[#setValueCalls]
local factPtrLink = factPtrSave.richText.segments[#factPtrSave.richText.segments]
check(factPtrLink.kind == 'reclink' and factPtrLink.node == currentNode(indiG),
  'the record link lands on the Fact\'s own owning record (indiG), not the Fact item itself')

-- Climbs through more than one level too -- MoveToRecordItem climbs all the way up
-- regardless of depth (issue #117: "if passed a source link for example you will get the
-- owning individual or family record").
local citationNode = { tag = 'SOUR', id = 88888, parent = factNode }
local citationPtr = newPtr()
citationPtr.list = { citationNode }
citationPtr.index = 1

freshSessionLogHelper.logActivity(citationPtr, "created")
local citationSave = setValueCalls[#setValueCalls]
local citationLink = citationSave.richText.segments[#citationSave.richText.segments]
check(citationLink.kind == 'reclink' and citationLink.node == currentNode(indiG),
  'a pointer nested two levels deep (a citation under a Fact) still climbs all the way to the owning record')

-- Defensive backstop: if the climb doesn't land on a record this fake tree actually has on
-- file (modelling a real-world "MoveToRecordItem couldn't resolve to anything usable" case),
-- validateLogActivity's re-check after climbing still catches it as a bad pointer instead of
-- reaching AddRecordLink with a broken one.
local orphanNode = { tag = 'DATA', id = 77777, parent = { tag = 'GHOST', id = 66666 } }
local orphanPtr = newPtr()
orphanPtr.list = { orphanNode }
orphanPtr.index = 1

local okOrphan, errOrphan = pcall(freshSessionLogHelper.logActivity, orphanPtr, "created")
check(okOrphan == false,
  'a pointer whose climb lands on something this fake tree has no record of raises an error rather than reaching AddRecordLink with a broken pointer')
check(contains(errOrphan, "DATA") and contains(errOrphan, "MoveToRecordItem"),
  'the error names the original item\'s own tag and that a climb was attempted (code review finding on issue #117: this backstop must stay as diagnosable as the nil-ptrRecord case it would otherwise be indistinguishable from, per ADR 0027)')

-- The climb only ever runs once action/media have already been validated (issue #117 code
-- review): MoveToRecordItem mutates its receiver in place, a caller-visible side effect on
-- an object the caller owns, so a call that's going to error on a bad action anyway must
-- leave the caller's own Fact pointer untouched, not climb it first and still fail.
local factPtrBadAction = newPtr()
factPtrBadAction.list = { factNode }
factPtrBadAction.index = 1

local okBadActionFactPtr = pcall(freshSessionLogHelper.logActivity, factPtrBadAction, nil)
check(okBadActionFactPtr == false, 'a Fact ptrRecord paired with a nil action still raises (the action check, not the pointer)')
check(fhGetTag(factPtrBadAction) == 'BIRT',
  'the Fact pointer itself is left untouched by the failed call -- the climb never ran, since action was invalid first')

------------------------------------------------------------------
-- ptrRecord accepts a qualified id string too (issue #114, grilling session 2026-08-17):
-- resolved via familyHelper.resolvePointer, the same as every other fhBridge.* pointer
-- argument (getAllDetails/getFactsByTag/createFact) -- logActivity was the one
-- write-capable helper that didn't, confirmed live during issue #113's own end-to-end
-- verification. No record-type restriction: resolvePointer resolves any of its 11
-- supported qualified-id prefixes, not just INDI/FAM -- a Session's log needs to be able
-- to point at any record type actually touched (an OBJE, a SOUR, etc.), not only
-- Individuals/Families.
------------------------------------------------------------------

package.loaded['sessionLogHelper'] = nil
local qidSessionLogHelper = require('sessionLogHelper')

recordsByTag["INDI"] = recordsByTag["INDI"] or {}
table.insert(recordsByTag["INDI"], { tag = "INDI", id = 219 })
local indiQidNode = recordsByTag["INDI"][#recordsByTag["INDI"]]

local rnotBeforeQid = #(recordsByTag["_RNOT"] or {})
qidSessionLogHelper.logActivity("I219", "created")
check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeQid + 1,
  'a qualified id string ptrRecord ("I219") succeeds the same way a live pointer does')

local qidIndiSave = setValueCalls[#setValueCalls]
local qidIndiSegments = qidIndiSave.richText.segments
local qidIndiLink = qidIndiSegments[#qidIndiSegments]
check(qidIndiLink.kind == 'reclink' and qidIndiLink.node == indiQidNode,
  'the resolved live pointer -- not the original string -- is what gets passed to AddRecordLink')

recordsByTag["FAM"] = recordsByTag["FAM"] or {}
table.insert(recordsByTag["FAM"], { tag = "FAM", id = 3 })
local famQidNode = recordsByTag["FAM"][#recordsByTag["FAM"]]

qidSessionLogHelper.logActivity("F3", "created")
local famQidSave = setValueCalls[#setValueCalls]
local famQidSegments = famQidSave.richText.segments
local famQidLink = famQidSegments[#famQidSegments]
check(famQidLink.kind == 'reclink' and famQidLink.node == famQidNode,
  'a FAM qualified id string ("F3") resolves and links correctly too')

recordsByTag["SOUR"] = recordsByTag["SOUR"] or {}
table.insert(recordsByTag["SOUR"], { tag = "SOUR", id = 77 })
local sourQidNode = recordsByTag["SOUR"][#recordsByTag["SOUR"]]

local okSourQid = pcall(qidSessionLogHelper.logActivity, "S77", "created")
check(okSourQid == true,
  'a non-INDI/FAM qualified id string ("S77", a Source) also succeeds -- no record-type restriction, unlike createFact')
local sourQidSave = setValueCalls[#setValueCalls]
local sourQidSegments = sourQidSave.richText.segments
local sourQidLink = sourQidSegments[#sourQidSegments]
check(sourQidLink.kind == 'reclink' and sourQidLink.node == sourQidNode,
  'the Source record link also points at the correctly-resolved node')

local okBareNumberQid, errBareNumberQid = pcall(qidSessionLogHelper.logActivity, 219, "created")
check(okBareNumberQid == false,
  'a bare number ptrRecord is still rejected -- ambiguous across every record type resolvePointer supports, same as getAllDetails/getFactsByTag/createFact (issue #65 precedent)')
check(contains(errBareNumberQid, "qualified id"),
  'the error is familyHelper.resolvePointer\'s own bare-number rejection, not a generic crash')

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

-- A fresh Fact fixture, not the module-level factPtr above -- that one was already climbed
-- (and so mutated in place, matching MoveToRecordItem's real "moves this pointer" contract)
-- by the earlier logActivity(factPtr, ...) call, so by now it points at indiG, not the Fact.
local factPtr2 = newPtr()
factPtr2.list = { factNode }
factPtr2.index = 1

local okValidateOnlyFactPtr, resolvedValidateOnlyFactPtr = pcall(freshSessionLogHelper.validateLogActivity, factPtr2, "created")
check(okValidateOnlyFactPtr == true, 'validateLogActivity also auto-corrects a Fact/sub-item ptrRecord (issue #117), same as logActivity')
check(resolvedValidateOnlyFactPtr == factPtr2 and currentNode(resolvedValidateOnlyFactPtr) == currentNode(indiG),
  'the returned pointer is the same object, now climbed to point at the Fact\'s owning record')

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

------------------------------------------------------------------
-- M.getNotePtr (issue #115): read-only accessor for the module-level notePtr, since it was
-- previously a private local -- bridgeSession.lua needs to read it (without creating one)
-- to decide whether to call fhOutputNote on Bridge close.
------------------------------------------------------------------

package.loaded['sessionLogHelper'] = nil
local accessorSessionLogHelper = require('sessionLogHelper')

check(accessorSessionLogHelper.getNotePtr() == nil,
  'getNotePtr returns nil before logActivity has ever been called this Session')

local indiAccessor = fhCreateItem("INDI")
accessorSessionLogHelper.logActivity(indiAccessor, "created")

check(accessorSessionLogHelper.getNotePtr() ~= nil,
  'getNotePtr returns non-nil once logActivity has created this Session\'s note')
check(currentNode(accessorSessionLogHelper.getNotePtr()).tag == '_RNOT',
  'getNotePtr returns the _RNOT record pointer itself, not its TEXT subfield')

------------------------------------------------------------------
-- M.setCommitCount (issue #133): bridge-side commit-counter plumbing.
------------------------------------------------------------------

package.loaded['sessionLogHelper'] = nil
local commitSessionLogHelper = require('sessionLogHelper')

local indiCommitA = fhCreateItem("INDI")
commitSessionLogHelper.logActivity(indiCommitA, "created")
local segmentsNoCount = setValueCalls[#setValueCalls].richText.segments
check(segmentsNoCount[#segmentsNoCount].kind == 'reclink',
  'with no commit count set, the record link is still the entry\'s last segment -- no stray count segment appended')

commitSessionLogHelper.setCommitCount(1)
local indiCommitB = fhCreateItem("INDI")
commitSessionLogHelper.logActivity(indiCommitB, "fact added Birth")
local segmentsWithCount = setValueCalls[#setValueCalls].richText.segments
local countSegment = segmentsWithCount[#segmentsWithCount]
check(countSegment.kind == 'text' and countSegment.text == ' (commit 1)' and countSegment.rich == false,
  'once setCommitCount is called, every subsequent entry appends the running count as its own trailing segment')

commitSessionLogHelper.setCommitCount(2)
local indiCommitC = fhCreateItem("INDI")
commitSessionLogHelper.logActivity(indiCommitC, "created")
local segmentsWithCount2 = setValueCalls[#setValueCalls].richText.segments
check(segmentsWithCount2[#segmentsWithCount2].text == ' (commit 2)',
  'a later setCommitCount call updates the count subsequent entries report')

------------------------------------------------------------------
-- M.recoverAfterRollback (issue #133): resyncs cached note state with what a rollback
-- actually left on disk, rather than unconditionally discarding it.
------------------------------------------------------------------

-- Case 1: the note record survives (it was already committed by an earlier call) --
-- only the pending entry this call tried to append gets rolled back. Simulated here by
-- forcing the next save to fail (standing in for a script whose write got rolled back
-- after logActivity had already appended to the in-memory buffer but before that entry
-- reached disk), then confirming recoverAfterRollback resyncs the buffer from the last
-- *saved* state, discarding the failed entry, and the note itself is unchanged -- so the
-- next logActivity call continues the SAME note rather than starting a new one.
-- markNoteCommitted is bridgeSession.lua's own signal, not textPtr:IsNull() -- see
-- noteConfirmed's own comment in sessionLogHelper.lua -- simulates every earlier call in
-- this test file having actually committed successfully, which they did.
commitSessionLogHelper.markNoteCommitted()

local notePtrBeforeRollback = commitSessionLogHelper.getNotePtr()
local rnotBeforeRollback = #(recordsByTag["_RNOT"] or {})

forceNextWriteFailure = true
local okFailedEntry = pcall(commitSessionLogHelper.logActivity, indiCommitC, "fact added Death")
check(okFailedEntry == false, 'a save failure still raises via checkWrite, same as before recoverAfterRollback existed')

commitSessionLogHelper.recoverAfterRollback()

check(commitSessionLogHelper.getNotePtr() == notePtrBeforeRollback,
  'recoverAfterRollback leaves the note pointer unchanged when the note record still resolves')

local indiCommitD = fhCreateItem("INDI")
commitSessionLogHelper.logActivity(indiCommitD, "created")
check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeRollback,
  'the next logActivity call after recoverAfterRollback creates no new _RNOT record -- it continues the same note')
check(commitSessionLogHelper.getNotePtr() == notePtrBeforeRollback,
  'the note is still the same record after the post-rollback logActivity call')

local segmentsPostRollback = setValueCalls[#setValueCalls].richText.segments
local deathEntryResurfaced = false
for _, seg in ipairs(segmentsPostRollback) do
  if seg.text and contains(seg.text, "fact added Death") then
    deathEntryResurfaced = true
  end
end
check(not deathEntryResurfaced,
  'the failed "fact added Death" entry never resurfaces in a later save -- recoverAfterRollback discarded it, not just left it stuck at the end')
check(segmentsPostRollback[#segmentsPostRollback].text == ' (commit 2)',
  'recoverAfterRollback does not touch commitCount -- only bridgeSession.lua manages that')

-- Case 2: no note exists yet to resync (e.g. a rollback of the very first call in a
-- Session, before any note was even created) -- recoverAfterRollback safely no-ops, and
-- the next logActivity call starts a fresh note exactly as a brand-new Session would.
package.loaded['sessionLogHelper'] = nil
local rollbackFreshSessionLogHelper = require('sessionLogHelper')

rollbackFreshSessionLogHelper.recoverAfterRollback()
check(rollbackFreshSessionLogHelper.getNotePtr() == nil,
  'recoverAfterRollback on a Session with no note yet leaves the note pointer nil, rather than erroring')

local rnotBeforeFreshRollback = #(recordsByTag["_RNOT"] or {})
local indiCommitE = fhCreateItem("INDI")
rollbackFreshSessionLogHelper.logActivity(indiCommitE, "created")
check(#(recordsByTag["_RNOT"] or {}) == rnotBeforeFreshRollback + 1,
  'the first logActivity call after a no-op recoverAfterRollback creates a brand-new _RNOT record, same as a fresh Session')

-- Case 3 (issue #133): the note record itself was created in this same not-yet-committed
-- call, so the rollback undid the note's creation too -- NOT just Case 2's "no note ever
-- existed". markNoteCommitted is never called here, mirroring a fresh Session's very first
-- run_lua call failing after logActivity's first-ever entry. textPtr:IsNull() can't tell
-- this case apart from Case 1 (see noteConfirmed's own comment), so this exercises the
-- noteConfirmed-driven branch directly.
package.loaded['sessionLogHelper'] = nil
local sameCallSessionLogHelper = require('sessionLogHelper')

local indiSameCall = fhCreateItem("INDI")
forceNextWriteFailure = true
local okSameCallEntry = pcall(sameCallSessionLogHelper.logActivity, indiSameCall, "fact added Death")
check(okSameCallEntry == false, 'the note-creating call still raises via checkWrite when its save fails')

local rnotAfterFailedCreate = #(recordsByTag["_RNOT"] or {})

sameCallSessionLogHelper.recoverAfterRollback()
check(sameCallSessionLogHelper.getNotePtr() == nil,
  'recoverAfterRollback discards the note pointer when the note itself was created in the same uncommitted call, not just when no note ever existed')

local indiSameCallNext = fhCreateItem("INDI")
sameCallSessionLogHelper.logActivity(indiSameCallNext, "created")
check(#(recordsByTag["_RNOT"] or {}) == rnotAfterFailedCreate + 1,
  'the next logActivity call creates a genuinely new _RNOT record rather than reusing the rolled-back one')

local segmentsSameCall = setValueCalls[#setValueCalls].richText.segments
local deathEntryResurfacedSameCall = false
for _, seg in ipairs(segmentsSameCall) do
  if seg.text and contains(seg.text, "fact added Death") then
    deathEntryResurfacedSameCall = true
  end
end
check(not deathEntryResurfacedSameCall,
  'the rolled-back note-creating entry never resurfaces in the new note')

------------------------------------------------------------------
-- validateLogActivity: an Excluded Individual's own record blocks the write, checked on
-- the guaranteed record-level pointer even when ptrRecord started as a Fact/sub-item and
-- had to climb (issue #141).
------------------------------------------------------------------

do
  local excludedIndi = fhCreateItem("INDI")
  addFlag(excludedIndi, "__PRIVATE")
  familyHelper.setPrivacySettings({ privateVisibility = "exclude", livingVisibility = "all" })

  local okExcluded, errExcluded = pcall(sessionLogHelper.validateLogActivity, excludedIndi, "created")
  check(not okExcluded, 'validateLogActivity raises for an Excluded Individual')
  check(contains(errExcluded, 'Excluded'), 'the error names the Excluded reason')

  -- A Fact/sub-item on the Excluded Individual must climb to the owning record first
  -- (fhHasParentItem/MoveToRecordItem), and only then hit the Excluded check.
  local factOnExcluded = currentNode(excludedIndi)
  local birtNode = { tag = "BIRT", id = nil, parent = factOnExcluded }
  local birtPtr = newPtr()
  birtPtr.list = { birtNode }
  birtPtr.index = 1
  local okFact, errFact = pcall(sessionLogHelper.validateLogActivity, birtPtr, "fact added Birth")
  check(not okFact, 'a Fact item climbed onto an Excluded Individual is also blocked, not just the record pointer itself')
  check(contains(errFact, 'Excluded'), 'the climbed-Fact-item error also names the Excluded reason')

  familyHelper.setPrivacySettings(nil)
end

t.report()
