-- Standalone tests for richTextHelper.lua. Run with: lua bridge/tests/richTextHelper.test.lua
-- No FH/socket dependency. Builds a small fake pointer + fake RichText object, scoped
-- narrowly to only what richTextHelper.lua actually calls: fhGetValueAsRichText,
-- fhNewRichText, fhSetValueAsRichText, fhGetQualifiedRecordId, and the RichText object's
-- own GetText/SetText methods. Unlike sourceHelper.test.lua/sessionLogHelper.test.lua, the
-- fake RichText here models GetText()'s 4-return-value shape (sText, bRich, tblRecLinks,
-- tblCitations) directly as canned per-scenario fixtures, since richTextHelper.lua's own
-- logic (index->qualifiedId text substitution, the citation-count guard) is what's under
-- test here -- not FH's own SetText/GetText engine, which was live-verified separately
-- against Family Historian Sample Project 8 (2026-08-15 grilling session, issue #107).

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'

local t = require('testHelpers').new()
local check, contains = t.check, t.contains

------------------------------------------------------------------
-- Fake pointer: identified by name; IsNull()/IsNotNull() driven by an explicit flag so a
-- "Null pointer" (a real, still-present linked-record slot per GetText()'s own docs) can be
-- modelled distinctly from a genuinely absent Lua value.
------------------------------------------------------------------

local PtrMethods = {}
PtrMethods.__index = PtrMethods

local function newPtr(name, isNull)
  return setmetatable({ name = name, null = isNull or false }, PtrMethods)
end

-- A pointer's "current node" when it's mid-child-walk (see MoveToFirstChildItem below) --
-- nil for every plain field/owner pointer (the ordinary case throughout this file), which
-- falls back to the .name/.null identity above.
local function currentChildNode(ptr)
  return ptr.list and ptr.list[ptr.index]
end

function PtrMethods:IsNull()
  if self.list then return currentChildNode(self) == nil end
  return self.null
end

function PtrMethods:IsNotNull()
  return not self:IsNull()
end

-- Needed only for familyHelper.recordVisibility's _FLGS walk (issue #141): parentPtr is
-- either an "owner" record pointer (its own .children, set by MoveToRecordItem below) or a
-- _FLGS node reached via a previous MoveToFirstChildItem call (its .children field, found
-- via currentChildNode) -- mirrors factHelper.test.lua/sessionLogHelper.test.lua's own.
function PtrMethods:MoveToFirstChildItem(parentPtr)
  local node = currentChildNode(parentPtr)
  self.list = (node and node.children) or parentPtr.children or {}
  self.index = 1
end

function PtrMethods:MoveNext()
  self.index = self.index + 1
end

-- Needed only for richTextHelper.lua's own Exclude check (issue #141): ptrRef is a
-- rich-text field pointer, optionally carrying a .owner fixture ({ name, children }
-- describing the Individual record it belongs to) set per-test below. No .owner set (every
-- pre-#141 fixture) climbs to a generic non-INDI owner, so recordVisibility trivially
-- returns "all" for it, same as today.
function PtrMethods:MoveToRecordItem(ptrRef)
  local owner = ptrRef.owner or { name = 'owner-record' }
  self.list = nil
  self.index = nil
  self.name = owner.name
  self.children = owner.children
  self.null = false
end

fhNewItemPtr = function() return newPtr('unset-ptr', false) end

local nullFieldPtr = newPtr('null-field', true)

------------------------------------------------------------------
-- Fake RichText object: GetText() returns a canned fixture (set via .fixture), SetText()
-- records what it was called with so setTftfText's own commit call can be inspected.
------------------------------------------------------------------

local RichTextMethods = {}
RichTextMethods.__index = RichTextMethods

local setTextCalls = {}

local function newFakeRichText(fixture)
  return setmetatable({ fixture = fixture }, RichTextMethods)
end

function RichTextMethods:GetText()
  local f = self.fixture
  return f.sText, f.bRich, f.tblRecLinks, f.tblCitations
end

function RichTextMethods:SetText(text, bIsRich, bTFTF)
  table.insert(setTextCalls, { text = text, bIsRich = bIsRich, bTFTF = bTFTF, obj = self })
end

------------------------------------------------------------------
-- Fake globals: one field pointer -> one fixture, resolved by fhGetValueAsRichText;
-- fhGetQualifiedRecordId resolves a linked pointer to its qualified id by name.
------------------------------------------------------------------

local fixturesByFieldPtr = {}

fhGetValueAsRichText = function(ptr)
  return newFakeRichText(fixturesByFieldPtr[ptr])
end

fhGetQualifiedRecordId = function(ptr)
  return ptr.name
end

-- Used by setTftfText's own write-result error message (issue #111, docs/adr/0028) to name
-- which field a failed write targeted (ptr.name, the ordinary case), and by
-- familyHelper.recordVisibility's _FLGS walk (issue #141) to read a child/flag node's own
-- tag once MoveToFirstChildItem has positioned ptr onto one (currentChildNode(ptr) ~= nil).
fhGetTag = function(ptr)
  local node = currentChildNode(ptr)
  if node then return node.tag end
  return ptr.name
end

-- Write-result failure injection (issue #111, docs/adr/0028): set true immediately before
-- the one call a fixture wants to fail; self-resets after firing once.
local forceNextWriteFailure = false

local setValueAsRichTextCalls = {}
fhSetValueAsRichText = function(ptr, richTextObj)
  table.insert(setValueAsRichTextCalls, { ptr = ptr, richText = richTextObj })
  if forceNextWriteFailure then
    forceNextWriteFailure = false
    return false
  end
  return true
end

fhNewRichText = function()
  return newFakeRichText({})
end

local richTextHelper = require('richTextHelper')

------------------------------------------------------------------
-- getTftfText: rich text with record links, no citations -- converts every index-based
-- <rec=N,...> reference to a self-contained <rec=QualifiedId,...> one.
------------------------------------------------------------------

local fieldA = newPtr('field-A')
local linkedI1 = newPtr('I1')
local linkedI2 = newPtr('I2')
fixturesByFieldPtr[fieldA] = {
  sText = '* First item <rec=1,"Anthony Edward MUNRO",auto>\n* Second item <rec=2,"Julia Amanda FISH",auto>',
  bRich = true,
  tblRecLinks = { [1] = linkedI1, [2] = linkedI2 },
  tblCitations = nil,
}

local resultA = richTextHelper.getTftfText(fieldA)
check(resultA.editable == true, 'a rich-text field with record links and no citations is reported editable')
check(resultA.text == '* First item <rec=I1,"Anthony Edward MUNRO",auto>\n* Second item <rec=I2,"Julia Amanda FISH",auto>',
  'every index-based <rec=N,...> reference is rewritten to a self-contained <rec=QualifiedId,...> one')

------------------------------------------------------------------
-- getTftfText: the same record referenced twice (two different <rec=N,...> tags sharing
-- one table index) converts both occurrences correctly, not just the first.
------------------------------------------------------------------

local fieldRepeated = newPtr('field-repeated')
fixturesByFieldPtr[fieldRepeated] = {
  sText = 'See <rec=1,"my father",text> -- also <rec=1,"John Smith",auto>.',
  bRich = true,
  tblRecLinks = { [1] = linkedI1 },
  tblCitations = nil,
}
local resultRepeated = richTextHelper.getTftfText(fieldRepeated)
check(resultRepeated.text == 'See <rec=I1,"my father",text> -- also <rec=I1,"John Smith",auto>.',
  'two <rec=1,...> tags sharing one table index both convert, not just the first occurrence')

------------------------------------------------------------------
-- getTftfText: no digit-prefix collision -- index 1 must not also match inside <rec=10,...>
------------------------------------------------------------------

local fieldCollision = newPtr('field-collision')
local linked10 = newPtr('I99')
fixturesByFieldPtr[fieldCollision] = {
  sText = '<rec=1,"one",auto> and <rec=10,"ten",auto>',
  bRich = true,
  tblRecLinks = { [1] = linkedI1, [10] = linked10 },
  tblCitations = nil,
}
local resultCollision = richTextHelper.getTftfText(fieldCollision)
check(resultCollision.text == '<rec=I1,"one",auto> and <rec=I99,"ten",auto>',
  'index 1 does not also rewrite inside <rec=10,...> -- both resolve to their own distinct qualified id')

------------------------------------------------------------------
-- getTftfText: a Null linked pointer (target record since deleted) is left as its original
-- numeric index rather than guessed at or crashing.
------------------------------------------------------------------

local fieldDangling = newPtr('field-dangling')
local danglingLink = newPtr('gone', true)
fixturesByFieldPtr[fieldDangling] = {
  sText = 'Mentions <rec=1,"deleted record",auto> here.',
  bRich = true,
  tblRecLinks = { [1] = danglingLink },
  tblCitations = nil,
}
local resultDangling = richTextHelper.getTftfText(fieldDangling)
check(resultDangling.text == 'Mentions <rec=1,"deleted record",auto> here.',
  'a Null linked pointer is left as its original numeric index, not guessed at or crashed on')
check(resultDangling.editable == true, 'a dangling link alone does not block editability -- only citations do')

------------------------------------------------------------------
-- getTftfText: rich text with no record links at all -- text passes through unchanged.
------------------------------------------------------------------

local fieldPlainRich = newPtr('field-plain-rich')
fixturesByFieldPtr[fieldPlainRich] = {
  sText = '<b>Just styled text</b>, no links.',
  bRich = true,
  tblRecLinks = nil,
  tblCitations = nil,
}
local resultPlainRich = richTextHelper.getTftfText(fieldPlainRich)
check(resultPlainRich.editable == true and resultPlainRich.text == '<b>Just styled text</b>, no links.',
  'rich text with no record links passes through unchanged and stays editable')

------------------------------------------------------------------
-- getTftfText: a genuinely plain-text (not rich) field passes through unchanged too.
------------------------------------------------------------------

local fieldPlain = newPtr('field-plain')
fixturesByFieldPtr[fieldPlain] = {
  sText = 'Just an ordinary string.',
  bRich = false,
  tblRecLinks = nil,
  tblCitations = nil,
}
local resultPlain = richTextHelper.getTftfText(fieldPlain)
check(resultPlain.editable == true and resultPlain.text == 'Just an ordinary string.',
  'a plain-text (non-rich) field is already valid tFTF and passes through unchanged')

------------------------------------------------------------------
-- getTftfText: citation guard -- a field with embedded citations is reported NOT editable,
-- with a reason naming the count, and the (unsafe) original text is still surfaced for
-- inspection rather than withheld.
------------------------------------------------------------------

local fieldCited = newPtr('field-cited')
local sourCitation = newPtr('SOUR-citation-1')
fixturesByFieldPtr[fieldCited] = {
  sText = 'Some text with a citation<cit=1>',
  bRich = true,
  tblRecLinks = nil,
  tblCitations = { [1] = sourCitation },
}
local resultCited = richTextHelper.getTftfText(fieldCited)
check(resultCited.editable == false, 'a field with an embedded citation is reported not editable')
check(contains(resultCited.reason, '1'), 'the reason names the citation count')
check(contains(resultCited.reason, 'citation'), 'the reason mentions citations specifically')
check(resultCited.text == 'Some text with a citation<cit=1>', 'the original (unsafe-to-rewrite) text is still surfaced for inspection')

------------------------------------------------------------------
-- getTftfText: invalid pointer
------------------------------------------------------------------

local okNilPtr, errNilPtr = pcall(richTextHelper.getTftfText, nil)
check(okNilPtr == false, 'getTftfText rejects a nil ptr')
check(contains(errNilPtr, 'ptr'), 'the nil-ptr error names ptr specifically')

local okNullPtr = pcall(richTextHelper.getTftfText, nullFieldPtr)
check(okNullPtr == false, 'getTftfText rejects a non-nil but IsNull() ptr')

local okStringPtr, errStringPtr = pcall(richTextHelper.getTftfText, "not a pointer")
check(okStringPtr == false, 'getTftfText rejects a wrong-typed (string) ptr rather than a raw Lua crash (issue #110)')
check(contains(errStringPtr, 'must point to'), 'the error is getTftfText\'s own message, not a raw "attempt to call a nil value (method \'IsNull\')" crash')

------------------------------------------------------------------
-- setTftfText: happy path -- no existing citations, commits via a fresh RichText object's
-- SetText(text, true, true), then fhSetValueAsRichText onto the target field.
------------------------------------------------------------------

local fieldWrite = newPtr('field-write')
fixturesByFieldPtr[fieldWrite] = {
  sText = 'old content',
  bRich = false,
  tblRecLinks = nil,
  tblCitations = nil,
}

local setTextCallCountBefore = #setTextCalls
local setValueCallCountBefore = #setValueAsRichTextCalls
richTextHelper.setTftfText(fieldWrite, '* New item <rec=I1,"Someone",auto>')

check(#setTextCalls == setTextCallCountBefore + 1, 'setTftfText calls SetText exactly once')
local lastSetText = setTextCalls[#setTextCalls]
check(lastSetText.text == '* New item <rec=I1,"Someone",auto>', 'SetText is called with the exact text passed in')
check(lastSetText.bIsRich == true and lastSetText.bTFTF == true, 'SetText is called in tFTF mode (bIsRich=true, bTFTF=true)')

check(#setValueAsRichTextCalls == setValueCallCountBefore + 1, 'setTftfText calls fhSetValueAsRichText exactly once')
local lastSetValue = setValueAsRichTextCalls[#setValueAsRichTextCalls]
check(lastSetValue.ptr == fieldWrite, 'fhSetValueAsRichText targets the field pointer passed in')
check(lastSetValue.richText == lastSetText.obj, 'fhSetValueAsRichText is called with the same object SetText was just called on')

------------------------------------------------------------------
-- setTftfText: citation guard fires at write time too (not just whatever getTftfText saw
-- earlier) -- and critically, neither SetText nor fhSetValueAsRichText is ever called when
-- it rejects, so a rejected call can never partially write.
------------------------------------------------------------------

local fieldCitedWrite = newPtr('field-cited-write')
fixturesByFieldPtr[fieldCitedWrite] = {
  sText = 'has a citation<cit=1>',
  bRich = true,
  tblRecLinks = nil,
  tblCitations = { [1] = sourCitation },
}

local setTextCallCountBeforeReject = #setTextCalls
local setValueCallCountBeforeReject = #setValueAsRichTextCalls
local okCitedWrite, errCitedWrite = pcall(richTextHelper.setTftfText, fieldCitedWrite, 'replacement text')

check(okCitedWrite == false, 'setTftfText refuses to rewrite a field that currently has citations')
check(contains(errCitedWrite, 'citation'), 'the rejection names citations specifically')
check(#setTextCalls == setTextCallCountBeforeReject, 'a rejected setTftfText call never calls SetText')
check(#setValueAsRichTextCalls == setValueCallCountBeforeReject, 'a rejected setTftfText call never calls fhSetValueAsRichText')

------------------------------------------------------------------
-- setTftfText: invalid arguments are rejected before any write, same never-partially-writes
-- guarantee as the citation guard above.
------------------------------------------------------------------

local setTextCallCountBeforeInvalid = #setTextCalls
local setValueCallCountBeforeInvalid = #setValueAsRichTextCalls

local okNilPtrWrite, errNilPtrWrite = pcall(richTextHelper.setTftfText, nil, 'text')
check(okNilPtrWrite == false, 'setTftfText rejects a nil ptr')
check(contains(errNilPtrWrite, 'ptr'), 'the nil-ptr error names ptr specifically')

local okBoolPtrWrite, errBoolPtrWrite = pcall(richTextHelper.setTftfText, true, 'text')
check(okBoolPtrWrite == false, 'setTftfText rejects a wrong-typed (boolean) ptr rather than a raw Lua crash (issue #110)')
check(contains(errBoolPtrWrite, 'must point to'), 'the error is setTftfText\'s own message, not a raw "attempt to index a boolean value" crash')

local okNonStringText, errNonStringText = pcall(richTextHelper.setTftfText, fieldWrite, 123)
check(okNonStringText == false, 'setTftfText rejects a non-string text argument')
check(contains(errNonStringText, 'text'), 'the non-string-text error names text specifically')

check(#setTextCalls == setTextCallCountBeforeInvalid, 'none of the invalid calls above ever called SetText')
check(#setValueAsRichTextCalls == setValueCallCountBeforeInvalid, 'none of the invalid calls above ever called fhSetValueAsRichText')

------------------------------------------------------------------
-- validateSetTftfText: the pure validation half, exported so sandbox.lua can run it
-- untracked before arming the write tracker (issue #97 pattern). Never writes, even on
-- success.
------------------------------------------------------------------

local setTextCallCountBeforeValidateOnly = #setTextCalls
local setValueCallCountBeforeValidateOnly = #setValueAsRichTextCalls

local okValidateOnly = pcall(richTextHelper.validateSetTftfText, fieldWrite, 'some text')
check(okValidateOnly == true, 'validateSetTftfText succeeds silently on valid input')
check(#setTextCalls == setTextCallCountBeforeValidateOnly, 'validateSetTftfText never calls SetText, even on success')
check(#setValueAsRichTextCalls == setValueCallCountBeforeValidateOnly, 'validateSetTftfText never calls fhSetValueAsRichText, even on success')

local okValidateOnlyCited = pcall(richTextHelper.validateSetTftfText, fieldCitedWrite, 'some text')
check(okValidateOnlyCited == false, 'validateSetTftfText rejects a citation-bearing field, same as setTftfText')

local okValidateOnlyBadType, errValidateOnlyBadType = pcall(richTextHelper.validateSetTftfText, 99, 'some text')
check(okValidateOnlyBadType == false, 'validateSetTftfText rejects a wrong-typed (number) ptr too, same as setTftfText')
check(contains(errValidateOnlyBadType, 'must point to'), 'the rejection is validateSetTftfText\'s own message, not a raw "attempt to index a number value" crash')
check(contains(errValidateOnlyBadType, '99'), 'the rejection names the actual value given')

------------------------------------------------------------------
-- Write-result check (issue #111, docs/adr/0028): a bOK=false from fhSetValueAsRichText
-- now raises via familyHelper.checkWrite instead of being silently discarded.
-- checkWrite itself is unit-tested directly in familyHelper.test.lua -- this just proves
-- setTftfText is wired to it.
------------------------------------------------------------------

local fieldWriteFailure = newPtr('field-write-failure')
fixturesByFieldPtr[fieldWriteFailure] = {
  sText = 'old content',
  bRich = false,
  tblRecLinks = nil,
  tblCitations = nil,
}

forceNextWriteFailure = true
local okWriteFail, errWriteFail = pcall(richTextHelper.setTftfText, fieldWriteFailure, 'replacement text')
check(okWriteFail == false, 'setTftfText raises when fhSetValueAsRichText itself fails')
check(contains(errWriteFail, 'setTftfText'), 'the failure names the function')
check(contains(errWriteFail, 'field-write-failure'), 'the failure names the target field (via fhGetTag)')

------------------------------------------------------------------
-- setTftfText/validateSetTftfText: an Excluded Individual's own record blocks the write --
-- ptr is always a field, never the record itself, so this climbs to the owning record via
-- MoveToRecordItem first (issue #141).
------------------------------------------------------------------

local familyHelper = require('familyHelper')

local fieldOnExcluded = newPtr('field-on-excluded')
fieldOnExcluded.owner = {
  name = 'INDI',  -- recordVisibility only walks _FLGS on a tag == "INDI" owner
  children = {
    { tag = '_FLGS', children = { { tag = '__PRIVATE', children = {} } } },
  },
}
fixturesByFieldPtr[fieldOnExcluded] = {
  sText = 'old content',
  bRich = false,
  tblRecLinks = nil,
  tblCitations = nil,
}

familyHelper.setPrivacySettings({ privateVisibility = 'exclude', livingVisibility = 'all' })

local setTextCallCountBeforeExcluded = #setTextCalls
local okExcludedWrite, errExcludedWrite = pcall(richTextHelper.setTftfText, fieldOnExcluded, 'replacement text')
check(okExcludedWrite == false, 'setTftfText raises when the field\'s owning Individual is Excluded')
check(contains(errExcludedWrite, 'Excluded'), 'the error names the Excluded reason')
check(#setTextCalls == setTextCallCountBeforeExcluded, 'a rejected setTftfText call never calls SetText')

local okValidateExcluded = pcall(richTextHelper.validateSetTftfText, fieldOnExcluded, 'some text')
check(okValidateExcluded == false, 'validateSetTftfText rejects the same Excluded field, same as setTftfText')

familyHelper.setPrivacySettings(nil)

-- The same field pointer, unchanged, succeeds again once Visibility is back to "all" --
-- proves the block is driven by the Session setting, not something baked into the fixture.
local okAfterReset = pcall(richTextHelper.validateSetTftfText, fieldOnExcluded, 'some text')
check(okAfterReset == true, 'the same field is no longer blocked once privateVisibility is back to "all"')

t.report()
