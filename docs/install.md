# FH MCP Bridge — Install Guide

This is the install path for **end users**: two small downloads, no building from source, no
command line, no hand-editing Claude Desktop's config file. If you're setting this project up
to develop or contribute to it instead, see [docs/build.md](build.md).

## What this is

FH MCP Bridge lets you ask Claude natural-language questions about your own Family Historian
(FH) tree — "who died between 1914 and 1918 in France or Belgium", "how many Munros are in
the tree", "who are so-and-so's grandparents" — and get answers grounded in your actual,
currently open FH data. No exporting a GEDCOM file, no separate app to learn.

It's two small pieces that talk to each other only on your own PC: a plugin that runs inside
FH, and a small background program ("server") that Claude Desktop talks to. The two steps
below install each half.

## Before you start

You need, already installed and working:

1. **Family Historian** itself (Windows natively, or via CrossOver on a Mac).
2. **[Claude Desktop](https://claude.ai/download)**.

That's everything.

## Step 1 — Install the MCP server into Claude Desktop

1. Download the `fh-mcp-bridge-X.Y.Z.mcpb` file from the
   [latest release](https://github.com/family-historian/Family-Historian-Bridge/releases) (the
   `X.Y.Z` is a version number).
2. In Claude Desktop, open **Settings → Extensions → Advanced Settings → Install Extension**,
   and select the downloaded `.mcpb` file.
3. If Claude Desktop was already open, restart it so it picks up the new extension. If you're
   opening it for the first time, nothing extra to do.

That's the whole server-side install — no `claude_desktop_config.json` to find or edit by
hand.

## Step 2 — Load the Bridge plugin into Family Historian

1. Download the `AI Assistant Connector.fh_lua` file from the same release.
2. Load it into FH, either way:
   - **Double-click it.** FH itself will offer to install it (a prompt from FH, not from this
     project) — follow that prompt through. It may also warn the plugin comes from an
     unidentified publisher; that's expected for any third-party FH plugin, click through it.
   - **Or, in FH:** go to **Tools → Plugins → New** (or **Import**), browse to wherever you
     downloaded `AI Assistant Connector.fh_lua`, open it, then click **Run**.

Either way, once it's loaded and running you'll see a small **"AI Assistant Connector"** dialog
appear inside FH, with **Start**/**Stop** buttons and a **Read-only**/**Read-write** choice.
Leave that dialog where it is — you'll use it every time you want to ask Claude about this
project.

## Step 3 — Use it

1. Open your project in Family Historian.
2. In the **"AI Assistant Connector"** dialog, choose **Read-only** (Claude can look things up
   only) or **Read-write** (Claude can also create, edit, and delete records), then click
   **Start**. FH's main window will lock while a session is running — that's expected, not a
   fault.
3. Switch to Claude Desktop and ask your question in plain English — no fixed list of
   commands to learn.
4. Click **Stop** in the dialog when you're done, to get FH back.

For what Claude can and can't do in each mode, how to get it to write you a standalone plugin
instead, and day-to-day troubleshooting, see **[docs/user-guide.md](user-guide.md)** —
everything from its "Using it" section onward applies here too.

## Privacy and security notes

Everything stays on your own PC (`127.0.0.1` only), with one deliberate exception (an
explicit, user-triggered check for updated FH help content), and scripts run in a restricted
sandbox that can only read FH data, never your filesystem or network. Full details:
[docs/user-guide.md, "Privacy and security notes"](user-guide.md#privacy-and-security-notes).
