# FH MCP Bridge: User Guide

Ask Claude natural-language questions about your own Family Historian (FH) project, like
"who died between 1914 and 1918 in France or Belgium", "how many Munros are in the tree",
or "who are so-and-so's grandparents", and get answers grounded in your actual, currently
open FH data. No GEDCOM export, no separate app.

A Session starts **Read-only** by default: Claude can look up and count things in your
tree, but not change anything. Pick **Read-write** at Start instead to additionally let
Claude create, edit, and delete records while answering your question (see
[What it can do right now](#what-it-can-do-right-now)).

This guide assumes both halves are already installed. Not installed yet? See
[docs/install.md](install.md) (end users — no building, no command line) or
[docs/build.md](build.md) (building from source instead).

## How it works, in short

Two pieces talk to each other over your own machine only (nothing goes over the internet
except your normal conversation with Claude and one deliberate exception: Claude can, if
you ask it to, check family-historian.co.uk for an updated copy of the bundled FH8 help
content, see [What it can do right now](#what-it-can-do-right-now)):

- A small **Bridge plugin** runs inside FH itself, with Start/Stop buttons.
- An **MCP server** runs alongside Claude Desktop and forwards Claude's questions to the
  Bridge as scripts, then hands the answers back.

You start a **Session** in FH (click Start) before asking Claude anything; FH's main
window is locked for the duration (that's expected, not a bug) and you get it back the
moment you click Stop.

## Using it

1. **Open your project in FH**, then in the "Claude MCP Bridge" dialog:
   - Pick **Read-only** (Claude can only look things up) or **Read-write** (Claude can
     also create, edit, and delete records). This choice holds for the whole Session;
     Stop and Start again to change it.
   - Set **Minutes:** to how long the Session should stay open with no activity before it
     auto-Stops (see step 4 below). Defaults to 5; change it before clicking Start, it's
     locked for the rest of the Session.
   - Optionally tick **Debug logging** (off by default) to have every `run_lua` script and
     its result written to a plain-text log file for this Session, useful if you need to
     see exactly what Claude ran (see [Troubleshooting](#troubleshooting)).
   - Click **Start**. The dialog shows "Listening..." and FH's main window locks. This is
     expected.
2. **Ask Claude your question**, in plain English, in your normal conversation. No fixed
   command list; ask however you'd ask a person.

   For the first question of a conversation, it helps to say explicitly that Claude should
   use the Bridge, so it doesn't default to general knowledge or skip a step it should take
   first:

   > Use the FH MCP Bridge. Call `describe_project` first to see this project's actual
   > shape, then `search_gedcom_knowledge('run_lua guidance')` before writing any `run_lua`
   > script; search `search_fh_help`/`search_gedcom_knowledge` for anything you're not
   > already certain of, don't guess at fh\*/fhu names.

   This isn't required (Claude can usually work it out on its own), but some MCP clients
   truncate a tool's own description before Claude ever sees it, so spelling this out
   yourself is a cheap way to make sure nothing gets missed.
3. If your question is genuinely ambiguous (an unclear place-name spelling, an unspecified
   number of generations), Claude will ask you to clarify rather than guess.
4. **Click Stop** when you're done to get FH back. If you forget, the Session
   auto-Stops after the **Minutes:** timeout (5 by default) of no activity, and the dialog
   returns to "Not listening." automatically.

## What it can do right now

In a **Read-only** Session, Claude can look things up and count/list/cross-reference, but
cannot create, edit, or delete anything in your project. In particular it can:

- Iterate every Individual and Family record.
- Read names, dates, places, and any Fact (birth, death, occupation, residence, etc.).
- Follow family relationships (parents, children, spouses) to answer ancestor/descendant
  questions.
- Check whether a Fact has a source citation attached.
- Read your project's own custom fact types (e.g. a military-history project's
  `_ATTR-REGIMENT`, `EVEN-ENLISTED`) as their real, resolved tags, not as a raw GEDCOM
  `FACT`/`EVEN` plus a `TYPE` subtag the way they'd sit in an export. This is what makes a
  question like "who died while serving in the armed forces" answerable at all, since that
  filter depends entirely on your project's own custom facts, which no fixed command could
  have anticipated.
- Give you a quick census of the whole project: record counts per record type, plus how
  often each tag and custom fact appears. A good first question when you haven't asked
  Claude anything about this project yet ("give me an overview of this project").
- Search Family Historian 8's own official help documentation (menus, features, dialogs,
  plugin authoring) and ground its answers in it, even with no Bridge Session running.
  This doesn't touch your tree data at all. The help content is bundled with the server;
  ask Claude to check for an update if you think it's stale and it'll fetch a fresh copy
  from family-historian.co.uk, the one thing this server ever does over the internet,
  and only when you ask for it.

In a **Read-write** Session, Claude can additionally create, edit, and delete records,
facts, source citations, and notes *while answering a live question*, the same way it
answers read-only questions, just with more of FH's API available to the script it
writes. Nothing here bypasses FH's own undo: Ctrl-Z always reverts the last change, and FH
automatically undoes a script's changes if it errors partway through (see CONTEXT.md "FH
auto-undo"). `describe_project`'s built-in project census always runs Read-only, even
during a Read-write Session; it never needs write access, so it doesn't get it.

Every write in a Read-write Session is also logged automatically. The first write of a
Session creates one Research Note in your tree with a `Title:`/`Type: mcp-log`/`Status:
closed`/`Date:` header, and each write after that (in the same or a later Session) adds a
bulleted entry with a link to the record it touched. This is built in, not optional, so
you can always see what Claude changed and when, and target these notes with a Smart
Folder later if you want to review or clean them up.

Getting a standalone plugin written for you (see below) is separate from either mode;
it's not bound by the Session's Access mode at all.

## Getting a standalone plugin written for you

Separately from asking live questions, you can ask Claude to write you a complete,
installable FH plugin, for example:

- "Write me a Report plugin that lists everyone's occupation next to their name."
- "Write me a Query plugin that counts how many people have each surname."

This is a different mode from the live Q&A above, not an extension of it:

- Claude doesn't run this script itself. It hands back the complete plugin as plain
  text, for you to save yourself as a `.fh_lua` file and install the normal FH way:
  double-click it on Windows, or use FH's own **Tools -> Plugins -> New** (or **Import**).
- No Bridge Session is needed for this; it doesn't touch your live project at all
  until you choose to install and run the plugin yourself, under FH's own permission
  model.
- Because you're the one reviewing and running it, it isn't limited by either Session
  Access mode the way a live question is. A generated plugin can do things (show a
  message box, read/write a file, edit your project) that asking Claude a question never
  can, even in a Read-write Session. This is intentional, not a gap in the sandbox above.
- Any line that uses one of those otherwise-off-limits functions is marked with a
  `-- FLAGGED` comment directly above it in the returned text. Read those lines before
  you install; that's the entire purpose of the flag, so don't skip past them just
  because "an AI wrote it."

Once you've reviewed it, you have two ways to install it:

- **Manual**: save the text yourself as a `.fh_lua` file and install it the normal FH way
  (double-click on Windows, or **Tools -> Plugins -> New/Import**), as described above.
- **Ask Claude to install it**: say so ("install it", "add it to my plugins") and Claude
  will call `install_fh_plugin` to write it straight into FH's Plugins folder. This needs
  an active Bridge Session (same as asking a live question) to look up where that folder
  is; if no Session is running, Claude will ask you to confirm the location instead (see
  "Where FH's Plugins folder is" above). It never overwrites an existing file; asking to
  install the same plugin again after a tweak adds "V2", then "V3", and so on, to both the
  filename and the plugin's own title. FH doesn't rescan its Plugins folder while the
  Plugins Dialog is open, so close and reopen **Tools -> Plugins** afterwards if you have it
  open, then select the new entry and click **Run**.

Tell Claude which kind you want, a **Report** plugin (shows in FH's Report Window) or a
**Query** plugin (shows a list in FH's Query Window), and what it should do.

## Troubleshooting

**"No FH Bridge Session is running"**: click Start in the Claude MCP Bridge dialog. Claude can't
start a Session itself; there's no way around clicking Start yourself.

**Session ended on its own**: either you clicked Stop, or the **Minutes:** idle timeout
(5 by default) passed with no question sent. Just click Start again.

**Bridge won't Start / "Failed to bind port 8734"**: something else already has port 8734
open, most likely an earlier copy of the plugin still running in FH's Plugin Editor. Close
any other running instance and try again.

**Claude's answer looks wrong**: Claude runs a fresh Lua script per question, so an
unusual question can occasionally expose a scripting bug rather than a data problem. Ask
it to double-check or explain how it got the number; it has full context on the script it
just ran. For a harder case, Stop the Session, tick **Debug logging**, Start again, and
reproduce the question. Every `run_lua` script and its result gets written to a
plain-text log file under your project's public folder for the rest of that Session.

**`run_lua` never shows up in Claude Desktop, and `claude_desktop_config.json` looks
correct** (only relevant if you installed via [docs/build.md](build.md)'s manual config-file
step, not the `.mcpb` in [docs/install.md](install.md)): newer Claude Desktop builds (the
unified/MSIX-packaged version, not the older Squirrel one) don't read
`claude_desktop_config.json` at all, so hand-editing it does nothing on those builds. There's
no supported workaround yet for that path if you're on one of these — switch to
[docs/install.md](install.md)'s `.mcpb` install instead; this is a known gap, not something
you're doing wrong.

## Privacy and security notes

- The Bridge only listens on `127.0.0.1` (your own machine). Nothing your data touches
  leaves your computer except your normal Claude conversation itself.
- No password or login is required to talk to the Bridge; anything on your machine that
  can reach `127.0.0.1:8734` while a Session is running could, in principle, do so too.
  This is an accepted trade-off for a single-user local tool, not an oversight.
- Scripts run in a restricted sandbox. Even a buggy or unexpected script can only read
  FH data, never touch your filesystem, network, or anything outside FH's own read API.
