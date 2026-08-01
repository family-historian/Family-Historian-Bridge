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

-- sessionLogHelper.logActivity(ptrRecord, action)
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
function M.logActivity(ptrRecord, action)
  if not notePtr then
    notePtr = fhCreateItem("_RNOT")
    buffer = fhNewRichText()
    buffer:AddText("Claude session log — " .. timestamp() .. "\n", false)
  else
    buffer:AddText("\n", false)
  end

  buffer:AddText(timestamp() .. " - " .. action .. ": ", false)
  buffer:AddRecordLink(ptrRecord, fhGetQualifiedRecordId(ptrRecord))
  fhSetValueAsRichText(notePtr, buffer)
end

return M
