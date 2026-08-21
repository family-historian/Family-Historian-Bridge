-- Logs a Read-write Session's record-creating activity into one Research Note (_RNOT) per
-- Session. Calls the real fh* globals directly (not sandboxed) -- sandbox.lua only wires
-- this module through during a read-write Session.
--
-- Module-level state (the note's item pointer, its TEXT subfield pointer, and the
-- RichText buffer mirroring what's saved so far) persists for the Session's lifetime via
-- require()'s module caching, so logActivity never re-reads the note back from FH.

local M = {}

local familyHelper = require('familyHelper')

local notePtr = nil  -- set on this Session's first logActivity call
local textPtr = nil
local buffer = nil
-- True once the current note has survived a commit at least once (issue #133). Distinct
-- from "textPtr resolves": a pointer into a record a rollback just undid does not reliably
-- report IsNull() == true, so liveness-checking textPtr is not a safe way to tell "this note
-- is durable" from "this note only existed inside the failed call". noteConfirmed is
-- instead driven explicitly by bridgeSession.lua, which alone knows when a commit actually
-- succeeded.
local noteConfirmed = false

local function timestamp(now)
  return os.date("%Y-%m-%d %H:%M", now)
end

local function timeOnly()
  return os.date("%H:%M")
end

-- Human-scannable date for the header's Date: line, e.g. "16 Aug 2026".
local function dateOnly(now)
  return os.date("%d %b %Y", now)
end

-- sessionLogHelper.logActivity(ptrRecord, action, media)
-- Records that `action` happened to ptrRecord (a live pointer or qualified id string,
-- e.g. "I219"). First call in a Session creates a new _RNOT record with a labelled
-- header (Title:/Type:/Status:/Date:) and the first log entry; later calls append a
-- bulleted entry with a live record link to the same note.
--
-- Title's text is what FH uses as the note's display name/Records Window title, so it
-- must stay a "Title:"-labelled first paragraph. Type/Status are fixed constants so the
-- user can target these notes with a Smart Folder later.
--
-- media (optional): {name, location} describing media the user still needs to add by
-- hand -- appends a "[ ] #ToDo Media to be added <name>" sub-line. This project never
-- touches media files/the filesystem itself.
--
-- Validates before touching the buffer or creating the record: the buffer is
-- module-level state that must not end up half-written, and a bad ptrRecord/action must
-- fail before any real write happens (a write followed by an error triggers FH's own
-- undo-dialog rollback, which is the wrong outcome for a caller mistake).

-- sessionLogHelper.validateLogActivity(ptrRecord, action, media)
-- The validation half of logActivity, extracted so sandbox.lua can call it before
-- arming the write tracker -- a rejected call here should never look like a write.
-- Returns the resolved live pointer for logActivity to reuse.
function M.validateLogActivity(ptrRecord, action, media)
  ptrRecord = familyHelper.resolvePointer(ptrRecord)
  local problem = familyHelper.pointerProblem(ptrRecord)
  if problem then
    error("logActivity: ptrRecord must point to the record this activity concerns" .. problem)
  end
  -- ptrRecord must be a record itself, not a Fact/sub-item (AddRecordLink requires a
  -- record). If it is a Fact/sub-item, MoveToRecordItem climbs to its owning record
  -- instead of erroring (docs/adr/0031) -- done after the action/media checks below
  -- since MoveToRecordItem mutates ptrRecord in place, and a call that's going to fail
  -- validation anyway shouldn't touch the caller's pointer first.
  if type(action) ~= "string" or action == "" then
    error("logActivity: action must be a non-empty string describing what happened")
  end
  if media and not media.name then
    error("media.name is required when a media detail is given")
  end
  if fhHasParentItem(ptrRecord) then
    local originalTag = tostring(fhGetTag(ptrRecord))  -- for the error message below
    ptrRecord:MoveToRecordItem(ptrRecord)
    -- Defensive backstop -- MoveToRecordItem should always resolve to a real record.
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

-- sessionLogHelper.getNotePtr()
-- Read-only accessor for the module-level _RNOT note pointer (nil until logActivity's
-- first call creates one), so callers can check whether a note exists without reaching
-- into this module's private state.
function M.getNotePtr()
  return notePtr
end

-- Running commit-count total (issue #133), set bridge-side only -- never through
-- sandbox.lua, so a run_lua script can't forge it. nil until bridgeSession.lua's first
-- read-write call sets it; logActivity appends nothing when nil (read-only Sessions, or
-- before the first write-mode call, never show a count).
local commitCount = nil

-- sessionLogHelper.setCommitCount(n)
-- Bridge-side only. Called by bridgeSession.lua with an optimistic "count so far,
-- including this pending call" value before each read-write run_lua call -- the true
-- post-commit count isn't known until after the script (and any logActivity call inside
-- it) has already run. Safe to set optimistically: if the script fails and its write gets
-- rolled back, the note entry carrying this count is rolled back with it.
function M.setCommitCount(n)
  commitCount = n
end

-- sessionLogHelper.markNoteCommitted()
-- Bridge-side only. Called by bridgeSession.lua exactly when a run_lua call's commit
-- actually succeeds, so this module knows the current note (if any) has now survived at
-- least one commit and is durable on disk. See noteConfirmed's own comment and
-- recoverAfterRollback below for why this explicit signal exists.
function M.markNoteCommitted()
  noteConfirmed = true
end

-- sessionLogHelper.recoverAfterRollback()
-- Bridge-side only. Called after a rolled-back write to resync this module's cached note
-- state with what a rollback actually left on disk (issue #133; see noteConfirmed's own
-- comment for why textPtr:IsNull() isn't used to tell the two cases apart).
--
-- Two cases, told apart by noteConfirmed:
-- - true: this Session's note already survived an earlier commit, so the rollback only
--   undid the pending entry this call tried to append -- the note record itself survives.
--   Re-fetching the buffer from fhGetValueAsRichText(textPtr) resyncs it to that committed
--   (rolled-back-to) state, so the next logActivity call appends onto the true on-disk
--   content, continuing the SAME note. Without this, the in-memory buffer would still
--   carry the rolled-back entry's text (the rollback primitive undoes the tree write, not
--   this module's own Lua table), silently resurrecting it on the next successful save.
--   AddText/AddRecordLink on a live-fetched RichText object appends to its end
--   (docs/adr/0025), so this buffer is safe to keep appending to exactly like a
--   freshly-created one.
-- - false: the note record itself was created in this same not-yet-committed call, so it
--   was rolled back away too -- nothing to re-fetch. Falls back to starting a brand-new
--   note next call, same as a fresh Session.
--
-- Does not touch commitCount -- bridgeSession.lua manages that separately since it isn't
-- reset by a rollback.
function M.recoverAfterRollback()
  if noteConfirmed then
    buffer = fhGetValueAsRichText(textPtr)
  else
    notePtr = nil
    textPtr = nil
    buffer = nil
  end
end

function M.logActivity(ptrRecord, action, media)
  local ptr = M.validateLogActivity(ptrRecord, action, media)

  if not notePtr then
    local newNotePtr = fhCreateItem("_RNOT")
    familyHelper.checkCreated(newNotePtr, "logActivity: failed to create this Session's _RNOT research-note record")
    notePtr = newNotePtr
    -- fhCreateItem("_RNOT") auto-creates the record's one mandatory TEXT subfield --
    -- fhSetValueAsRichText must target that child (via "~.TEXT"), not notePtr itself.
    textPtr = fhNewItemPtr()
    textPtr:MoveTo(notePtr, "~.TEXT")
    buffer = fhNewRichText()
    local now = os.time()  -- shared so Title:'s timestamp and Date: can't disagree
    -- Title: line, bold +2pt (FTF's <fs> is a relative delta, no absolute-point option).
    -- Markup goes through its own bRich=true call; the label/timestamp stay bRich=false
    -- so they're auto-escaped.
    buffer:AddText("<b><fs=\"+2\">", true)
    buffer:AddText("Title: Claude session log - " .. timestamp(now), false)
    buffer:AddText("</fs></b>\n", true)
    buffer:AddText("Type: mcp-log\nStatus: closed\nDate: " .. dateOnly(now) .. "\n\n", false)
  else
    buffer:AddText("\n", false)
  end

  -- Each entry is its own bulleted paragraph -- "* " must be the first thing in the
  -- paragraph, so it needs its own bRich=true call before the auto-escaped text/link.
  buffer:AddText("* ", true)
  buffer:AddText(timeOnly() .. " - " .. action .. ": ", false)
  buffer:AddRecordLink(ptr)  -- live FTF record link: label stays current if the record is renamed

  -- Running commit-count total (issue #133) -- only when bridgeSession.lua has set one via
  -- setCommitCount, so a read-only Session (or any call before the first write-mode
  -- request) never shows a stray count.
  if commitCount ~= nil then
    buffer:AddText(" (commit " .. commitCount .. ")", false)
  end

  if media then
    local subline = "[ ] #ToDo Media to be added " .. media.name
    if media.location then
      subline = subline .. " (" .. media.location .. ")"
    end
    buffer:AddText("\n", false)
    buffer:AddText(">", true)  -- own bRich=true call, same reason as the bullet above
    buffer:AddText(subline, false)
  end

  familyHelper.checkWrite(fhSetValueAsRichText(textPtr, buffer), "logActivity: failed to save this entry to the session's research note")
end

return M
