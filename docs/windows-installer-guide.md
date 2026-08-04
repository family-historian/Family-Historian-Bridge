# FH MCP Bridge — Windows Installer Guide

This guide is for installing FH MCP Bridge using the **Windows installer**
(`FH-MCP-Bridge-Setup-X.Y.Z.exe`) — no command line, no Node.js, nothing to build. If
you were handed a link to a `.exe` file rather than a copy of the project's source code,
this is the guide you want.

*(If instead you have the full project folder and were planning to build it yourself,
use [docs/user-guide.md](user-guide.md) instead — its "Install (clean machine)" section
covers that path.)*

## What this is

FH MCP Bridge lets you ask Claude natural-language questions about your own Family
Historian (FH) tree — "who died between 1914 and 1918 in France or Belgium", "how many
Munros are in the tree", "who are so-and-so's grandparents" — and get answers grounded in
your actual, currently open FH data. No exporting a GEDCOM file, no separate app to learn.

It's two small pieces that talk to each other only on your own PC: a plugin that runs
inside FH, and a small background program ("server") that Claude Desktop talks to. The
installer sets up both.

## Before you start

You need, already installed and working:

1. **Windows 10 or 11.**
2. **Family Historian** itself.
3. **[Claude Desktop](https://claude.ai/download)**.

That's everything. Unlike building from source, you do **not** need Node.js or any
other developer tools — the installer brings its own self-contained copy of what the
server needs to run.

## Step 1 — Get the installer

Get the `FH-MCP-Bridge-Setup-X.Y.Z.exe` file (the `X.Y.Z` is a version number, e.g.
`0.6.0`) from wherever it was shared with you, and save it somewhere you can find it
again, like your Downloads folder.

## Step 2 — Run it

Double-click the `.exe` file.

- **Windows may show a blue "Windows protected your PC" screen** (SmartScreen). This is
  expected for a small, independently-published tool that hasn't paid for a code-signing
  certificate — it isn't a sign anything is wrong. Click **More info**, then **Run
  anyway**.
- You will **not** be asked for an administrator password — the installer installs just
  for your own Windows user account, not system-wide.
- Click through the wizard (**Next**, **Install**). It only takes a few seconds.
- On the final page, leave **"Open the Bridge plugin in Family Historian now"** ticked
  (it's ticked by default) and click **Finish**.

Three things happen automatically as part of this, before you click Finish:

- The program files are installed to a folder under your own user profile (no need to
  remember where — you won't normally need to go there).
- **Claude Desktop's configuration is updated automatically** so it knows how to talk to
  the Bridge. Any other MCP tools you already had configured are left alone.
- The Bridge plugin file is put in place, ready for the next step.

## Step 3 — Load the plugin into Family Historian

If you left the checkbox ticked in Step 2, Windows will now try to open the plugin file,
and **Family Historian itself will offer to install it** — a prompt from FH, not from
this installer. Follow that prompt through (it may also warn that the plugin comes from
an unidentified publisher; that's expected for any third-party FH plugin, click through
it).

If you missed that, or unticked the box, do it manually instead:

1. In Family Historian, go to **Tools → Plugins → New** (or **Import**).
2. Browse to the `Claude MCP Bridge.fh_lua` file. It's inside wherever the installer put
   things — under `AppData\Local\Programs\FH MCP Bridge\bridge\` in your user profile
   (type `%LOCALAPPDATA%\Programs\FH MCP Bridge\bridge\` into File Explorer's address bar
   to jump straight there).
3. Open it, then click **Run**.

Either way, once it's loaded and running you'll see a small **"Claude MCP Bridge"**
dialog appear inside FH, with **Start**/**Stop** buttons and a **Read-only**/**Read-write**
choice. Leave that dialog where it is — you'll use it every time you want to ask Claude
about this project.

*(Unlike installing by hand, you don't need to work out which "Plugins" folder belongs to
your version of FH — opening the file through FH's own prompt or its Plugins dialog
handles that for you.)*

## Step 4 — Restart Claude Desktop

If Claude Desktop was already open while you ran the installer, close it completely
(check it isn't still sitting in the Windows system tray, bottom-right of your screen)
and reopen it, so it picks up the new configuration. If it wasn't running yet, just open
it normally — nothing extra to do.

## Step 5 — Use it

1. Open your project in Family Historian.
2. In the **"Claude MCP Bridge"** dialog, choose **Read-only** (Claude can look things up
   only) or **Read-write** (Claude can also create, edit, and delete records), then click
   **Start**. FH's main window will lock while a session is running — that's expected,
   not a fault.
3. Switch to Claude Desktop and ask your question in plain English — no fixed list of
   commands to learn.
4. Click **Stop** in the dialog when you're done, to get FH back. If you forget, it stops
   itself automatically after 5 minutes of no activity.

For what Claude can and can't do in each mode, how to get it to write you a standalone
plugin instead, and general day-to-day troubleshooting (not specific to this installer),
see **[docs/user-guide.md](user-guide.md)**, particularly the
[Using it](user-guide.md#using-it), [What it can do right now](user-guide.md#what-it-can-do-right-now),
and [Troubleshooting](user-guide.md#troubleshooting) sections — everything from Step 5
onward in that guide applies here too, regardless of how you installed.

## Installer-specific troubleshooting

**A message box says Claude Desktop's configuration couldn't be updated** — the
installer still finished; only that one automatic step failed. The message names a log
file, `config-merge.log`, in the same folder the program was installed to (under
`AppData\Local\Programs\FH MCP Bridge\` in your user profile). Open it in Notepad for
details. To retry: find `config-merge.ps1` in that same folder, right-click it, and
choose **Run with PowerShell** — no command line needed. If it still fails, you can add
the entry to Claude Desktop's config by hand; see the "manual fallback" box below.

**Manual fallback for Step 2's automatic Claude Desktop setup** — open (or create)
`%APPDATA%\Claude\claude_desktop_config.json` in Notepad and make sure it contains an
entry like this (merge it in alongside anything already there, don't just overwrite the
whole file if other tools are configured):

```json
{
  "mcpServers": {
    "fh-mcp-bridge": {
      "command": "%LOCALAPPDATA%\\Programs\\FH MCP Bridge\\node.exe",
      "args": ["%LOCALAPPDATA%\\Programs\\FH MCP Bridge\\server\\dist\\index.js"]
    }
  }
}
```

Then restart Claude Desktop.

**Your antivirus flags or removes `node.exe` after install** — the installer includes
its own private, portable copy of Node.js (needed to run the server) rather than
requiring you to install one system-wide. Some antivirus tools are wary of any unfamiliar
`.exe` doing this. If it gets quarantined, restore it from quarantine/allow it — it's the
program's own runtime, not something separate it downloaded.

**Bridge won't Start in FH / "Failed to bind port 8734"** — something else already has
that port open, most likely an earlier copy of the plugin still running. Close any other
running instance in FH and try Start again.

**Uninstalling** — use Windows **Settings → Apps →** find **"FH MCP Bridge"** →
**Uninstall**. This removes the installed program files, but it does **not** remove the
`fh-mcp-bridge` entry it added to Claude Desktop's configuration, or the plugin file
already loaded into FH — remove those yourself (in FH's Plugins dialog, and by editing
`claude_desktop_config.json` as above) if you want a completely clean removal.

## Privacy and security notes

Same as any other install method — see
[docs/user-guide.md, "Privacy and security notes"](user-guide.md#privacy-and-security-notes):
everything stays on your own PC (`127.0.0.1` only), with one deliberate exception (an
explicit, user-triggered check for updated FH help content), and scripts run in a
restricted sandbox that can only read FH data, never your filesystem or network.
