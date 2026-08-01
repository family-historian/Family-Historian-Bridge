-- Logs a Read-write Session's record-creating activity into one Research Note (_RNOT) per
-- Session. Same fhBridge shape as citeSource/createSourceFromTemplate in
-- bridge/sourceHelper.lua (issue #36, from a grilling session 2026-08-01).
--
-- Calls the real fh* globals directly (not a sandboxed copy), the same way sourceHelper.lua
-- does -- sandbox.lua must only ever wire this module through during a read-write Session.
--
-- Exploits that the whole Bridge plugin is one continuously-running Lua process for a
-- Session's lifetime: the module-level state below (the Research Note's own item pointer,
-- and the RichText buffer mirroring everything saved to it so far) persists naturally
-- across every run_lua call in that Session, via require()'s module caching -- and is gone
-- on the next Session, since a fresh plugin load runs this file's top level again from
-- scratch. This means M.logActivity never needs to read the note's existing content back
-- from FH and merge into it, and callers never need to track or pass back a note pointer of
-- their own.

local M = {}

-- nil until this Session's first M.logActivity call.
local notePtr = nil
local buffer = nil

local function timestamp()
  return os.date("%Y-%m-%d %H:%M")
end

-- sessionLogHelper.logActivity(ptrRecord, action, media)
-- Given an item pointer to the record an action concerns (e.g. the Individual just
-- created, or the one a fact was just added to) and a short description of what happened
-- (e.g. "created", "fact added Birth"): on this Session's first call, creates a new _RNOT
-- record titled with a creation timestamp (e.g. "Claude session log — 2026-08-01 14:32")
-- and writes the first log entry into it. Every subsequent call in the same Session
-- appends a further entry to that same note, leaving every earlier entry untouched, and
-- never creates a second note. The record reference in each entry is a live FTF record
-- link (RichText's AddRecordLink), labelled with the record's qualified id
-- (fhGetQualifiedRecordId) -- not plain text -- so opening the note in FH lets the user
-- click straight through to each record touched.
--
-- media (optional, issue #39): a {name, location} table describing media the user still
-- needs to add by hand once the Session ends -- this project never touches the media
-- file's bytes or the filesystem for that (see the 2026-08-01 grilling session on issue
-- #23). When given, appends an indented "[ ] #ToDo Media to be added <name>" sub-line
-- (plain FTF text, not an interactive checkbox) directly under the entry, with location
-- appended in parentheses when one was mentioned. Strictly opt-in per call -- omitting
-- media produces no sub-line, as before.
--
-- Validates media.name up front, before touching the buffer, matching sourceHelper.lua's
-- own validate-before-mutate convention -- the buffer is module-level state that persists
-- across calls, so a bad call throwing partway through would otherwise leave a stray,
-- never-flushed entry for the next successful call to inherit.
function M.logActivity(ptrRecord, action, media)
  if media and not media.name then
    error("media.name is required when a media detail is given")
  end

  if not notePtr then
    notePtr = fhCreateItem("_RNOT")
    buffer = fhNewRichText()
    buffer:AddText("Claude session log — " .. timestamp() .. "\n", false)
  else
    buffer:AddText("\n", false)
  end

  buffer:AddText(timestamp() .. " - " .. action .. ": ", false)
  buffer:AddRecordLink(ptrRecord, fhGetQualifiedRecordId(ptrRecord))

  if media then
    local subline = "\n      [ ] #ToDo Media to be added " .. media.name
    if media.location then
      subline = subline .. " (" .. media.location .. ")"
    end
    buffer:AddText(subline, false)
  end

  fhSetValueAsRichText(notePtr, buffer)
end

return M
