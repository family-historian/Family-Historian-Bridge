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

local function timestamp()
  return os.date("%Y-%m-%d %H:%M")
end

local function timeOnly()
  return os.date("%H:%M")
end

-- sessionLogHelper.logActivity(ptrRecord, action, media)
-- Given an item pointer to the record an action concerns (e.g. the Individual just
-- created, or the one a fact was just added to) and a short description of what happened
-- (e.g. "created", "fact added Birth"): on this Session's first call, creates a new _RNOT
-- record with a bold, +2pt heading paragraph timestamped at creation (e.g. "Claude session
-- log - 2026-08-01 14:32"), followed by a static, default-font intro paragraph ("The
-- following updates were applied to the project:", issue #79, written once alongside the
-- heading, not repeated per entry), and writes the first log entry into it. Every
-- subsequent call in the same Session appends a further entry to that same note,
-- leaving every earlier entry untouched, and never creates a second note. Each entry is its
-- own bulleted ("* ") FTF paragraph, in default (non-bold, default-size) font, and carries
-- only a time (not a full date) -- the heading's timestamp already gives the date, and a
-- Session running over midnight is still evident from an entry's time going backwards
-- (issue #79). The record reference in each entry is a live FTF record link (RichText's
-- AddRecordLink, called with no display-text argument so FH treats it as an "automatic"
-- link) -- not plain text -- so opening the note in FH lets the user click straight through
-- to each record touched, and the label always shows that record's current display name
-- (e.g. the person's name), updating on its own if that name later changes, rather than a
-- name or id frozen at the moment this entry was logged.
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
function M.validateLogActivity(ptrRecord, action, media)
  local problem = familyHelper.pointerProblem(ptrRecord)
  if problem then
    error("logActivity: ptrRecord must point to the record this activity concerns" .. problem)
  end
  -- fhHasParentItem is FH's own documented way to tell a record item apart from a
  -- field/Fact item ("record items do not have parent items, but all other items... do")
  -- -- ptrRecord must always be the record itself (e.g. the Individual just created, or
  -- the one a fact was just added to -- never the fact), matching this function's own
  -- doc comment above and the AddRecordLink call this feeds: an unnoticed Fact pointer
  -- here would still create a "successful" record link, just to the wrong (or a
  -- meaningless) thing, with nothing to signal the mistake (issue #110 follow-up,
  -- grilling session).
  if fhHasParentItem(ptrRecord) then
    error("logActivity: ptrRecord must point to the record this activity concerns, not a Fact or sub-item within one -- got a '" .. tostring(fhGetTag(ptrRecord)) .. "' item")
  end
  if type(action) ~= "string" or action == "" then
    error("logActivity: action must be a non-empty string describing what happened")
  end
  if media and not media.name then
    error("media.name is required when a media detail is given")
  end
end

function M.logActivity(ptrRecord, action, media)
  M.validateLogActivity(ptrRecord, action, media)

  if not notePtr then
    notePtr = fhCreateItem("_RNOT")
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
    -- Heading paragraph: bold + a fixed +2pt bump (issue #79). FTF's <fs> is only ever a
    -- relative delta off the user's own default Notes font size -- there's no absolute-point
    -- command and no API to read that default, so "+2" is a fixed bump, not a literal 12pt
    -- guarantee. The <b>/<fs> markers go through their own bRich=true call; the timestamp
    -- stays on a separate bRich=false call so it's auto-escaped without needing fhFtfEncode.
    buffer:AddText("<b><fs=\"+2\">", true)
    buffer:AddText("Claude session log - " .. timestamp(), false)
    -- The extra "\n" leaves a blank paragraph between the heading and the intro line below
    -- (issue #79 follow-up).
    buffer:AddText("</fs></b>\n\n", true)
    -- Static intro paragraph, written once alongside the heading (issue #79), default font.
    -- No markup in it, so it stays a single bRich=false call -- no separate rich-markup call
    -- needed the way the heading/bullet/indent markers each require one.
    buffer:AddText("The following updates were applied to the project:\n", false)
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
  buffer:AddRecordLink(ptrRecord)

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

  fhSetValueAsRichText(textPtr, buffer)
end

return M
