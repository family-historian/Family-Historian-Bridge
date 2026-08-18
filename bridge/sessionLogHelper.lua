-- Logs a Read-write Session's record-creating activity into one Research Note (_RNOT) per
-- Session. Same fhBridge shape as citeSource/createSourceFromTemplate in
-- bridge/sourceHelper.lua (issue #36, from a grilling session 2026-08-01).
--
-- Calls the real fh* globals directly (not a sandboxed copy), the same way sourceHelper.lua
-- does -- sandbox.lua must only ever wire this module through during a read-write Session.
--
-- Exploits that the whole Bridge plugin is one continuously-running Lua process for a
-- Session's lifetime: the module-level state below (the Research Note's own item pointer,
-- a pointer to its one mandatory TEXT subfield, and the RichText buffer mirroring
-- everything saved to it so far) persists naturally across every run_lua call in that
-- Session, via require()'s module caching -- and is gone on the next Session, since a
-- fresh plugin load runs this file's top level again from scratch. This means
-- M.logActivity never needs to read the note's existing content back from FH and merge
-- into it, and callers never need to track or pass back a note pointer of their own.

local M = {}

-- Reused for the shared pcall-guarded pointer check (pointerProblem, issue #110,
-- docs/adr/0027) that validateLogActivity's ptrRecord check below now uses instead of
-- its own copy of the "not ptr or ptr:IsNull()" idiom -- familyHelper.lua has no
-- require()s of its own, so this introduces no cycle.
local familyHelper = require('familyHelper')

-- nil until this Session's first M.logActivity call.
local notePtr = nil
local textPtr = nil
local buffer = nil

-- now (optional): an os.time() instant to format instead of the current time -- lets the
-- header below stamp Title: and Date: off one shared "now" rather than each taking its own
-- separate os.date() reading (issue #112 cleanup).
local function timestamp(now)
  return os.date("%Y-%m-%d %H:%M", now)
end

local function timeOnly()
  return os.date("%H:%M")
end

-- Human-scannable, date-only format for the header's Date: line (e.g. "16 Aug 2026") --
-- deliberately distinct from timestamp()'s "%Y-%m-%d %H:%M", since Date: is read by a
-- person scanning the Records Window, not re-parsed (issue #112).
local function dateOnly(now)
  return os.date("%d %b %Y", now)
end

-- sessionLogHelper.logActivity(ptrRecord, action, media)
-- Given an item pointer to the record an action concerns (e.g. the Individual just
-- created, or the one a fact was just added to) and a short description of what happened
-- (e.g. "created", "fact added Birth"): on this Session's first call, creates a new _RNOT
-- record with a four-line labelled header -- Title:/Type:/Status:/Date: -- and writes the
-- first log entry into it. Every subsequent call in the same Session appends a further
-- entry to that same note, leaving every earlier entry untouched, and never creates a
-- second note.
--
-- The header (issue #112, docs/adr/0029-logactivity-labelled-title-type-status-date-header.md)
-- replaces the old free-form heading + static intro paragraph:
--   Title: Claude session log - 2026-08-16 14:32   (bold, +2pt -- see below)
--   Type: mcp-log
--   Status: closed
--   Date: 16 Aug 2026
-- Only Title keeps the bold/+2pt styling the old heading had; Type/Status/Date are plain.
-- This isn't cosmetic: FH derives a _RNOT record's fhGetDisplayText and its name in the
-- Records Window from a Title:-labelled first paragraph (the same general mechanism behind
-- fhGetLabelledText/fhSetLabelledText), so Title's value becomes this record's actual name
-- everywhere in FH, not just an in-note heading -- confirmed live that FH's Title:-paragraph
-- detection still works with the FTF markup around it, so there was no need to drop the
-- styling for safety. Type ("mcp-log") and Status ("closed") are both fixed constants on
-- every note this helper creates, so the user can target them with a Smart Folder or query
-- for bulk cleanup once reviewed. Date carries its own human-scannable, date-only format
-- (dateOnly() above), distinct from Title's embedded timestamp -- it's for a person scanning
-- the Records Window, not for re-parsing. A blank paragraph still separates the header from
-- the first entry, the same visual gap issue #79 established, just with the (now-removed)
-- static intro line no longer sitting in between. No backfill: notes already created by past
-- Sessions keep their old heading+intro layout.
--
-- Every subsequent entry is its own bulleted ("* ") FTF paragraph, in default (non-bold,
-- default-size) font, and carries only a time (not a full date) -- the header's Date: line
-- already gives the date, and a Session running over midnight is still evident from an
-- entry's time going backwards (issue #79). The record reference in each entry is a live FTF
-- record link (RichText's AddRecordLink, called with no display-text argument so FH treats it
-- as an "automatic" link) -- not plain text -- so opening the note in FH lets the user click
-- straight through to each record touched, and the label always shows that record's current
-- display name (e.g. the person's name), updating on its own if that name later changes,
-- rather than a name or id frozen at the moment this entry was logged.
--
-- media (optional, issue #39): a {name, location} table describing media the user still
-- needs to add by hand once the Session ends -- this project never touches the media
-- file's bytes or the filesystem for that (see the 2026-08-01 grilling session on issue
-- #23). When given, appends a "[ ] #ToDo Media to be added <name>" sub-line as its own
-- indented (">") FTF paragraph (issue #79; plain FTF text, not an interactive checkbox)
-- directly under the entry, with location appended in parentheses when one was mentioned.
-- Strictly opt-in per call -- omitting media produces no sub-line, as before.
--
-- Validates ptrRecord/action/media.name up front, before touching the buffer or creating
-- the _RNOT record, matching sourceHelper.lua's own validate-before-mutate convention (and
-- reusing familyHelper.pointerProblem for the pointer check specifically -- the shared,
-- pcall-guarded check every fhBridge.* pointer-argument check now goes through, issue #110,
-- docs/adr/0027 -- rather than inventing a second phrasing) -- for two separate reasons:
-- the buffer is module-level state that persists across calls, so a bad call throwing
-- partway through would otherwise leave a stray, never-flushed entry for the next successful
-- call to inherit; and, on this Session's first call specifically, a bad ptrRecord/action
-- would otherwise reach fhCreateItem/AddRecordLink for real before failing, which flips
-- sandbox.lua's write tracker and triggers ADR 0005's full write-mode-error rollback (ending
-- the Session and prompting FH's own undo dialog) for what's actually just a caller mistake
-- with nothing yet on the tree to undo (issue #95, from a live run_lua call that passed a
-- nil ptrRecord and only found out via that whole rollback path).
-- sessionLogHelper.validateLogActivity(ptrRecord, action, media)
-- The pure validation half of M.logActivity below, extracted (issue #97) so sandbox.lua can
-- call it on its own, untracked, before arming the write tracker -- flipping tracker.wrote
-- purely from entering the wrapped fhBridge.logActivity call (as the old single-function
-- wrapping did) meant even a call rejected right here still armed ADR 0005's rollback path,
-- for a call that (by definition, once this errors) never touched the tree. M.logActivity
-- itself still calls this first too, so direct callers/tests keep today's single-call,
-- validate-then-mutate contract unchanged.
--
-- ptrRecord may be a live Item Pointer or a qualified id string (e.g. "I219", "F3", or any
-- other record type resolvePointer supports -- no INDI/FAM-only restriction, unlike
-- createFact: a Session's log needs to be able to point at any record type actually touched)
-- -- familyHelper.resolvePointer, matching createFact's own validateCreateFact pattern
-- (issue #114). logActivity was the one write-capable fhBridge helper that didn't already do
-- this, confirmed live during issue #113's own end-to-end verification (Family Historian
-- Sample Project 8): fhBridge.logActivity("I2", "...") raised "ptrRecord must point to the
-- record this activity concerns -- got string (I2), not a live Item Pointer", ending the
-- Session via the usual write-then-error rollback after a real write had already landed.
--
-- Returns the resolved live pointer (same "validate once, mutate reuses the result"
-- contract as factHelper.validateCreateFact/sourceHelper.validateCiteSource) -- M.logActivity
-- below needs it too, since its own AddRecordLink call must receive a live pointer, never the
-- original qualified id string.
function M.validateLogActivity(ptrRecord, action, media)
  ptrRecord = familyHelper.resolvePointer(ptrRecord)
  local problem = familyHelper.pointerProblem(ptrRecord)
  if problem then
    error("logActivity: ptrRecord must point to the record this activity concerns" .. problem)
  end
  -- fhHasParentItem is FH's own documented way to tell a record item apart from a
  -- field/Fact item ("record items do not have parent items, but all other items... do")
  -- -- ptrRecord must ultimately be the record itself (e.g. the Individual just created,
  -- or the one a fact was just added to), matching the AddRecordLink call this feeds
  -- ("must point to a record", per FH's own AddRecordLink docs).
  --
  -- Issue #110 originally rejected a Fact/sub-item pointer outright here: an unnoticed one
  -- would still create a "successful" record link, just to the wrong (or a meaningless)
  -- thing, with nothing to signal the mistake. Issue #117 (2026-08-18 grilling session)
  -- reverses that in favour of silently climbing to the owning record instead of erroring --
  -- confirmed live: a script that had already done the real work of a multi-step write (new
  -- Individual, family link, census fact) lost all of it to ADR 0005's write-then-error
  -- rollback because this was the write's very last call and it passed the just-created
  -- Fact, not its owning record -- a targeting mistake, not a data mistake, and the log call
  -- is exactly the wrong place for that to be fatal. ptr:MoveToRecordItem(ptrRef) is FH's
  -- own documented way to climb from any item to its owning record, at whatever depth (a
  -- Fact, a citation, a DATA subfield) -- safe to do silently here because it can only ever
  -- resolve to that item's own real owning record, never a different one, so it can't paper
  -- over a "wrong record entirely" mistake, only a "right record, wrong item within it" one.
  -- See docs/adr/0031-logactivity-auto-corrects-fact-pointer-to-owning-record.md.
  --
  -- The climb is deliberately ordered after the action/media checks below (not right here,
  -- where the Fact-vs-record distinction is actually explained) -- MoveToRecordItem mutates
  -- ptrRecord in place, a caller-visible side effect on an object the caller owns, and this
  -- function's own long-standing contract is to validate everything up front before touching
  -- anything (see M.logActivity's doc comment: "the buffer is module-level state..."). A call
  -- that's going to error on a bad action/media anyway should leave the caller's own pointer
  -- object untouched, not climb it first and then still fail.
  if type(action) ~= "string" or action == "" then
    error("logActivity: action must be a non-empty string describing what happened")
  end
  if media and not media.name then
    error("media.name is required when a media detail is given")
  end
  if fhHasParentItem(ptrRecord) then
    -- Captured before the climb specifically so the backstop errors below can still name
    -- what was actually passed -- pointerProblem's own "" case (a genuinely-null pointer)
    -- would otherwise be indistinguishable from the plain nil/IsNull() ptrRecord case
    -- (issue #95) once ptrRecord itself has already been climbed away from the original
    -- item, the exact "can't tell this apart from an internal crash" failure ADR 0027 was
    -- written to close (code review finding on issue #117).
    local originalTag = tostring(fhGetTag(ptrRecord))
    ptrRecord:MoveToRecordItem(ptrRecord)
    -- Defensive backstop, not the expected path -- MoveToRecordItem should always resolve
    -- to a real record for any genuine item. Re-running the same two checks turns a
    -- genuinely bizarre item shape into this function's own clear error instead of a
    -- confusing downstream AddRecordLink failure.
    problem = familyHelper.pointerProblem(ptrRecord)
    if problem then
      error("logActivity: ptrRecord's owning record could not be resolved via MoveToRecordItem from a '" .. originalTag .. "' item" .. problem)
    end
    if fhHasParentItem(ptrRecord) then
      error("logActivity: ptrRecord must point to the record this activity concerns, not a Fact or sub-item within one -- got a '" .. tostring(fhGetTag(ptrRecord)) .. "' item (climbed from a '" .. originalTag .. "' item)")
    end
  end
  return ptrRecord
end

function M.logActivity(ptrRecord, action, media)
  local ptr = M.validateLogActivity(ptrRecord, action, media)

  if not notePtr then
    local newNotePtr = fhCreateItem("_RNOT")
    familyHelper.checkCreated(newNotePtr, "logActivity: failed to create this Session's _RNOT research-note record")
    notePtr = newNotePtr
    -- FH auto-creates a _RNOT record's one mandatory TEXT subfield as part of fhCreateItem
    -- itself -- fhSetValueAsRichText must target that child item, not notePtr itself
    -- (confirmed live: fhSetValueAsRichText(notePtr, ...) silently returns false and
    -- writes nothing, since the record's own top-level pointer never held the value).
    -- MoveTo's "~.TEXT" reaches the already-created child directly, no fhCreateItem call
    -- needed (a second fhCreateItem("TEXT", notePtr) would fight the "exactly one" TEXT
    -- subfield FH already made).
    textPtr = fhNewItemPtr()
    textPtr:MoveTo(notePtr, "~.TEXT")
    buffer = fhNewRichText()
    -- Captured once and formatted two ways below (Title:'s timestamp, Date:'s date-only
    -- form) rather than each calling os.date() separately, so the two can't disagree if
    -- note creation happens to straddle a midnight boundary (issue #112 cleanup).
    local now = os.time()
    -- Title: line -- bold + a fixed +2pt bump (issue #79, kept through issue #112). FTF's
    -- <fs> is only ever a relative delta off the user's own default Notes font size --
    -- there's no absolute-point command and no API to read that default, so "+2" is a fixed
    -- bump, not a literal 12pt guarantee. The <b>/<fs> markers go through their own
    -- bRich=true call; the "Title: " label and timestamp stay on a separate bRich=false call
    -- so they're auto-escaped without needing fhFtfEncode. This is the paragraph FH reads to
    -- derive the _RNOT record's own fhGetDisplayText/Records Window name (issue #112,
    -- docs/adr/0029) -- confirmed live that FH's Title:-paragraph detection still works with
    -- this markup around it, so only this line (not Type:/Status:/Date: below) keeps it.
    buffer:AddText("<b><fs=\"+2\">", true)
    buffer:AddText("Title: Claude session log - " .. timestamp(now), false)
    buffer:AddText("</fs></b>\n", true)
    -- Type:/Status:/Date: lines -- fixed constants plus dateOnly()'s human-scannable date,
    -- distinct from Title's embedded timestamp. One plain (non-FTF-markup) call covers all
    -- three, since nothing but ordinary "\n"s separates them -- the fixed Type/Status values
    -- let the user target these notes with a Smart Folder or query for bulk cleanup once
    -- reviewed. The trailing "\n" leaves a blank paragraph between the header and the first
    -- entry below, the same gap issue #79 established, just moved here now that the old
    -- static intro line (which used to carry it) is gone.
    buffer:AddText("Type: mcp-log\nStatus: closed\nDate: " .. dateOnly(now) .. "\n\n", false)
  else
    buffer:AddText("\n", false)
  end

  -- Each entry is its own bulleted FTF paragraph (issue #79) -- the "* " bullet marker must
  -- be the first thing in the paragraph, so it goes through its own bRich=true call before
  -- the (auto-escaped, bRich=false) time/action text and the record link. The date is no
  -- longer repeated per entry -- the heading above already carries it, and a Session running
  -- over midnight still shows up as the entries' times going backwards.
  buffer:AddText("* ", true)
  buffer:AddText(timeOnly() .. " - " .. action .. ": ", false)
  buffer:AddRecordLink(ptr)

  if media then
    -- Its own FTF indent paragraph (leading ">", issue #79) rather than literal leading
    -- spaces -- the ">" marker needs its own bRich=true call for the same paragraph-start
    -- reason as the bullet marker above.
    local subline = "[ ] #ToDo Media to be added " .. media.name
    if media.location then
      subline = subline .. " (" .. media.location .. ")"
    end
    buffer:AddText("\n", false)
    buffer:AddText(">", true)
    buffer:AddText(subline, false)
  end

  familyHelper.checkWrite(fhSetValueAsRichText(textPtr, buffer), "logActivity: failed to save this entry to the session's research note")
end

return M
