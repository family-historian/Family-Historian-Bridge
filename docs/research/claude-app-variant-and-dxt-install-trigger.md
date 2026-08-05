# Detecting old vs. new Claude Desktop on Windows, and triggering `.dxt`/`.mcpb` install

Research ticket: [issue #58](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/58),
part of map [issue #56](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/56).
Feeds Ticket C (the real installer change) — this document does not decide anything, it
only answers the two feasibility/fact questions #58 asks.

**Note on location**: following the precedent set by
`docs/research/fhu-introspection-feasibility.md`, this file lives at `docs/research/`,
sibling to `docs/adr/` and `docs/agents/`.

---

## Verdict, up front

**Q1 (detecting old vs. new Claude app variant): confirmed, medium-high confidence, but
not the way the ticket first framed it.** There genuinely are two distinct Windows
install technologies — an older **Squirrel-based** install (`%LOCALAPPDATA%\AnthropicClaude\Claude.exe`)
and a newer **MSIX/AppX-packaged** install (no standalone `.exe`, package family
`Claude_pzs8sxrjxfjjc`, lives under protected `C:\Program Files\WindowsApps\`) — and Cowork
(the feature that motivated #56) requires the MSIX build ([§1.1](#11-two-genuinely-distinct-windows-builds)).
But **the reliable signal is packaging technology, not the raw version number** the
ticket's title mentions (`v1.24012.11+`) — version numbering itself changed shape across
the Squirrel→MSIX switch (old: `1.1.2685.0`-style; new: `1.24012.11.0`-style), so "v1.24012.11"
is best read as "the version #56's reporter happened to be on," not a documented cutoff
([§1.4](#14-why-a-version-number-threshold-is-the-wrong-primary-signal)). The most
reliable, cheaply-checkable-from-PowerShell/Inno-Setup signal is: **does
`%LOCALAPPDATA%\AnthropicClaude\Claude.exe` exist?** If yes → old Squirrel build, safe to
run `config-merge.ps1`. If no → check for the MSIX package via `Get-AppxPackage` → new
build, skip the config-merge and use `.dxt`/`.mcpb` instead ([§1.5](#15-recommended-check-and-how-to-run-it)).
**Confirmed** file-existence facts come from Anthropic's own bug tracker (GitHub issues,
primary source in the sense that they're first-party-filed and quote real log/error text);
**unconfirmed** is the *exact* registry uninstall-key name and any marker file/folder
specific to Claude's own MSIX build beyond the standard `Get-AppxPackage` mechanism — flagged
throughout, see [§4](#4-what-remains-unknown--needs-verification-on-a-real-machine).

**Q2 (triggering `.dxt` install): confirmed, high confidence, for the mechanism; medium
confidence for whether it plays out identically to `.fh_lua`.** Anthropic's own current
documentation states plainly that a `.mcpb`/`.dxt` file is installed by "**Double-click**
the `.mcpb` file" as method 1 of 3 (the others being drag-and-drop onto the Claude window,
and Settings → Extensions → Advanced settings → Install Extension…) — [Anthropic,
"Build a desktop extension with MCPB," Quickstart step 5 and "How users install your
MCPB"](https://claude.com/docs/connectors/building/mcpb). This is consistent with `.dxt`/`.mcpb`
being a registered Windows file type that a plain `ShellExecute`/Inno `Exec ewNoWait` open
would trigger — the same shape as this repo's existing `.fh_lua` shellexec
(`installer\fh-mcp-bridge.iss` lines 51–54). **No CLI flag or `claude://` URI action for
extension installation is documented anywhere** — the only documented `claude://` actions
are new chat / existing chat / project / Code session / Cowork session, not extension
install ([§2.2](#22-cli-flags-and-the-claude-uri-scheme-no-install-trigger-documented)).
**What's not independently confirmed**: whether Windows registers `.dxt`/`.mcpb` via a
classic `HKEY_CLASSES_ROOT` file association (which `ShellExecute` needs) or via an
MSIX-package `windows.fileTypeAssociation` manifest extension (which behaves the same way
from a calling program's point of view, but I found no primary source stating this
explicitly for Claude's package) — and real GitHub bug reports show the underlying
install handler (`installDxtFromDirectory`) can fail silently on some Windows/MSIX builds
even when triggered through Claude's own Settings UI, which is a live risk for a
shellexec-triggered flow too ([§2.3](#23-known-failure-modes-worth-planning-around)).

---

## 1. Detecting old vs. new Claude Desktop on Windows

### 1.1 Two genuinely distinct Windows builds

Two different Windows packaging technologies for "Claude Desktop" are confirmed to
coexist, from Anthropic's own first-party GitHub issue tracker (`anthropics/claude-code`,
which is also where Claude Desktop bugs are filed):

- **Squirrel-based** (the older technology): a per-user installer that drops the app under
  `%LocalAppData%\AnthropicClaude`. Confirmed directly:

  > "`%LocalAppData%\AnthropicClaude` contained a `SquirrelTemp` folder, `update.exe`, and
  > `app-<version>/squirrel.exe` — Squirrel's standard layout"
  > — [anthropics/claude-code#79307](https://github.com/anthropics/claude-code/issues/79307)

  > "Squirrel installation location: `C:\Users\XX\AppData\Local\AnthropicClaude\`"
  > "Last Working Version: 1.1.2685 (Squirrel-based)"
  > — [anthropics/claude-code#25162](https://github.com/anthropics/claude-code/issues/25162)

- **MSIX/AppX-based** (the newer technology, required for Cowork): no standalone `.exe` at
  a fixed user-writable path at all. Confirmed directly:

  > "current Claude Desktop for Windows ships only as an **MSIX/AppX package**... There is
  > **no** `%LOCALAPPDATA%\AnthropicClaude\Claude.exe` and no `%LOCALAPPDATA%\Programs\claude`.
  > The app lives in protected `WindowsApps` and is launchable only via its
  > AppUserModelID (`Claude_pzs8sxrjxfjjc!Claude`) or the `claude://` URI protocol."
  > — [anthropics/claude-code#69353](https://github.com/anthropics/claude-code/issues/69353)

  > "Claude Desktop MSIX, package family `Claude_pzs8sxrjxfjjc`"
  > "`C:\Program Files\WindowsApps\Claude_1.24012.11.0_...\app\resources\cowork-svc.exe`"
  > — [anthropics/claude-code#83932](https://github.com/anthropics/claude-code/issues/83932)

- Cowork (the feature #56 is about) **requires** the MSIX build, and there is **no
  automatic upgrade path** from an existing Squirrel install:

  > "Existing Claude Desktop users on Windows with the Squirrel-based installation cannot
  > upgrade to the new MSIX-packaged version (**required for Cowork**). The
  > `ClaudeSetup.exe` bootstrapper silently fails without any user-facing error message."
  > "The Squirrel updater checks
  > `https://downloads.claude.ai/releases/win32/x64/RELEASES?id=AnthropicClaude&localVersion=1.1.2685`
  > and receives no update. The MSIX version is not published through the Squirrel update
  > channel, so existing users have no automatic upgrade path."
  > — [anthropics/claude-code#25162](https://github.com/anthropics/claude-code/issues/25162)
  > (issue opened 2026-02-12, referencing the Cowork launch on 2026-02-10)

**Confidence: high** that these are two real, distinct Windows packaging technologies
(direct quotes, internally consistent across four independent issues, corroborated by
error codes and literal file/registry paths). **Medium** on exact product naming — none of
these primary sources use the term "CCD" that #56's own body used; that appears to be
`jane`'s own informal shorthand for "Cowork/CCD build" rather than an Anthropic-official
name, so treat "CCD" as this repo's internal label, not a documented Anthropic term.

### 1.2 Is this the same axis as "old-style Desktop honors `claude_desktop_config.json`, new one doesn't"?

Plausibly yes, but **not independently confirmed as the same axis** by a primary source
that states it explicitly. What is confirmed: current Anthropic-published configuration
documentation for the *managed* (enterprise/3P) configuration surface makes **no mention
of `claude_desktop_config.json`** at all — it describes only a registry-policy path
(`HKLM`/`HKCU\SOFTWARE\Policies\Claude`) and a local `configLibrary` directory of
per-connector JSON files, not a single flat config file
([claude.com/docs/third-party/claude-desktop/configuration](https://claude.com/docs/third-party/claude-desktop/configuration)).
That's consistent with — but doesn't directly prove — issue #56's reporter's own
observation that the installed app "never once reads or references
`claude_desktop_config.json` for MCP servers" and instead "rewrites it wholesale on its
own save cycle" (#56 body, `jane`'s own investigation, not a third-party source — treat as
this repo's own primary evidence, not independently re-verified here). **Confidence:
medium** — the packaging-technology split (§1.1) is solidly confirmed; that it's *the
exact same split* as the config-file-honoring split is inference from #56's report plus
circumstantial support from the docs' silence on `claude_desktop_config.json`, not a
directly-quotable "old builds read the file, new ones don't" statement from Anthropic.

### 1.3 Does the `.exe` expose a version resource PowerShell/Inno can read?

**Only for the Squirrel build, and only if you already know it's Squirrel.** `Claude.exe`
under `%LOCALAPPDATA%\AnthropicClaude\` is a normal Win32 PE executable, so both of these
work against it:

- PowerShell: `[System.Diagnostics.FileVersionInfo]::GetVersionInfo(string fileName)` —
  "Returns a `FileVersionInfo` representing the version information associated with the
  specified file" — reads the file's `FileVersion`/`ProductVersion` etc. from its Win32
  version resource
  ([Microsoft Learn, `FileVersionInfo.GetVersionInfo(String)`](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.fileversioninfo.getversioninfo)).
- Inno Setup `[Code]`: `function GetVersionNumbers(const Filename: String; var VersionMS,
  VersionLS: Cardinal): Boolean;` — "Gets the version numbers of the specified file.
  Returns True if successful, False otherwise."
  ([jrsoftware.org, Inno Setup ISPP/Pascal Script function reference, `GetVersionNumbers`](https://jrsoftware.org/ishelp/topic_isxfunc_getversionnumbers.htm)).

**The MSIX build has no such file to point either function at** — per §1.1, there is
"no `%LOCALAPPDATA%\AnthropicClaude\Claude.exe`" once on MSIX
([#69353](https://github.com/anthropics/claude-code/issues/69353)). Reading its version
means querying the Appx package database instead:

- PowerShell: `Get-AppxPackage [-Name <String>]` — "Gets a list of the app packages that
  are installed in a user profile," returning `AppxPackage` objects (which carry a
  `.Version` property, e.g. `Version` field on the object, though the exact property name
  wasn't itself quoted in the fetched doc excerpt — see caveat below) — module `Appx`,
  cmdlet documented at
  [Microsoft Learn, `Get-AppxPackage`](https://learn.microsoft.com/en-us/powershell/module/appx/get-appxpackage).
  Corroborating real usage from a live bug report: `Get-AppxPackage | Where-Object
  {$_.Name -like "*Claude*" -or $_.Name -like "*Anthropic*"}` was used to check for MSIX
  registration and "returned nothing" on a Squirrel-only machine
  ([#79307](https://github.com/anthropics/claude-code/issues/79307)) — confirming the
  cmdlet is the real, working check people actually use against this app, not just a
  theoretical API.
- Inno Setup's `[Code]` section has **no built-in Appx-package cmdlet equivalent** —
  querying `Get-AppxPackage` from Inno Setup would mean shelling out to
  `powershell.exe -Command "Get-AppxPackage -Name '*Claude*'..."` via `Exec`, the same
  pattern `fh-mcp-bridge.iss`'s `RunConfigMerge` already uses to invoke
  `config-merge.ps1` (lines 63–92).

**Confidence: high** on the API signatures themselves (both fetched directly from their
respective official docs); **medium** on the exact `AppxPackage` object property name to
read the version from (the Microsoft Learn page fetched didn't enumerate output
properties in the excerpt captured) — **flagged as needing confirmation on a real
machine**, though `Version` is the well-known standard property name for this cmdlet.

### 1.4 Why a version-number threshold is the wrong primary signal

The ticket's title cites "v1.24012.11+ confirmed affected in #56" as a candidate
threshold. Two things from the primary sources argue against leaning on the raw number:

1. **The version numbering scheme itself changed shape across the Squirrel→MSIX switch.**
   Squirrel-era versions look like `1.1.2685.0` (three-ish meaningful digits) — see
   [#25162](https://github.com/anthropics/claude-code/issues/25162) ("Last Working
   Version: 1.1.2685") and [#40044](https://github.com/anthropics/claude-code/issues/40044)
   ("`Claude_1.1.9134.0_x64_`"). MSIX-era versions look like `1.24012.11.0`, `1.25927.0.0`
   — see [#83932](https://github.com/anthropics/claude-code/issues/83932) and Anthropic's
   own [Claude Desktop changelog](https://claude.com/docs/cowork/changelog), which lists a
   dense, closely-dated sequence (`v1.11187.4` on 2026-06-05 through `v1.25927.0` on
   2026-08-04) all in the new large-middle-number shape. A numeric `>= 1.24012.11`
   comparison would happen to work today only because the two numbering schemes don't
   overlap in range — not because Anthropic documented a cutoff.
2. **"v1.24012.11" is not documented anywhere as a named milestone** — it doesn't appear
   in the fetched changelog as a release with feature-flag significance; its own changelog
   entry says "No user-facing changes" in General/Code/Cowork, with only 3P/MCP-connector
   fixes listed ([`claude.com/docs/cowork/changelog`](https://claude.com/docs/cowork/changelog),
   `v1.24012.11` entry, 2026-08-03). It reads as simply "the version #56's reporter
   happened to be running that week," not a threshold Anthropic drew a line at. The real
   dividing line, per §1.1, is the Cowork launch date (~2026-02-10) and the
   Squirrel-vs-MSIX packaging split, not a version number.

**Confidence: high** that leaning on packaging-technology detection (§1.5) is more robust
than a version-number comparison, given the scheme change is directly evidenced.

### 1.5 Recommended check, and how to run it

Given §1.1–§1.4, the most defensible check an installer can do, using only functions
confirmed above:

**PowerShell** (what `config-merge.ps1` or a new pre-flight script would run):

```powershell
$squirrelExe = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Claude.exe'

if (Test-Path $squirrelExe) {
    # Old-style Squirrel build confirmed present -- safe to merge claude_desktop_config.json.
    # Optionally read its version:
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($squirrelExe)
    # $versionInfo.FileVersion is now available if further gating is ever needed.
} else {
    # No Squirrel exe. Check for the MSIX/unified build before concluding "not installed at all".
    $msixPkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
    if ($msixPkg) {
        # New unified (MSIX) build -- do NOT merge claude_desktop_config.json; use .dxt/.mcpb instead.
    } else {
        # Neither found -- Claude Desktop likely not installed, or installed somewhere
        # this check doesn't cover (unconfirmed edge case, see §4).
    }
}
```

- `Test-Path`/file existence check against `%LOCALAPPDATA%\AnthropicClaude\Claude.exe` is
  standard PowerShell, not something requiring a fetched citation beyond confirming the
  path itself from §1.1's sources.
- `[System.Diagnostics.FileVersionInfo]::GetVersionInfo(...)` per §1.3.
- `Get-AppxPackage -Name '*Claude*'` per §1.3, mirroring the real diagnostic command
  already used in a live Anthropic bug report
  ([#79307](https://github.com/anthropics/claude-code/issues/79307)).

**Inno Setup `[Code]`** equivalent, using functions confirmed in §1.3 and via
`jrsoftware.org`:

```pascal
function IsOldSquirrelClaudeInstalled(): Boolean;
begin
  Result := FileExists(ExpandConstant('{localappdata}\AnthropicClaude\Claude.exe'));
end;
```

`FileExists(const Name: String): Boolean` — "Returns True if the specified file exists."
([jrsoftware.org, `FileExists`](https://jrsoftware.org/ishelp/topic_isxfunc_fileexists.htm)).
Detecting the MSIX build from Pascal Script directly has no confirmed built-in
equivalent to `Get-AppxPackage` — the pragmatic route (not independently verified working,
but architecturally consistent with how this repo already shells out to PowerShell for
`config-merge.ps1`, `fh-mcp-bridge.iss` lines 63–92) is calling `powershell.exe -NoProfile
-Command "..."` via `Exec` and parsing its exit code or output, the same `Exec`
signature already in use in this file.

Two functions that could theoretically help but were **not needed given the above, and
are only mentioned for completeness/future use**: `RegKeyExists(const RootKey: HKEY;
const SubKeyName: String): Boolean` and `RegQueryStringValue(const RootKey: HKEY; const
SubKeyName, ValueName: String; var ResultStr: String): Boolean`
([jrsoftware.org: `RegKeyExists`](https://jrsoftware.org/ishelp/topic_isxfunc_regkeyexists.htm),
[`RegQueryStringValue`](https://jrsoftware.org/ishelp/topic_isxfunc_regquerystringvalue.htm)) —
useful if a specific registry uninstall-key name for either build is ever confirmed (see
§4), but no such key name is confirmed by a primary source at the time of writing, so no
registry-based code sketch is given as fact here.

**Confidence: medium-high.** The file-existence and `Get-AppxPackage` checks are built
from confirmed real paths/commands used in Anthropic's own bug reports; the Pascal Script
sketch composes only functions independently confirmed from jrsoftware.org. What's
*not* independently re-run or tested here is whether this exact script, run against a
real Windows machine with either build installed, behaves as expected — see §4.

---

## 2. Triggering Claude's `.dxt`/`.mcpb` install flow programmatically

### 2.1 Double-click / file-open is the documented mechanism

Anthropic's current official documentation for building MCPB (formerly DXT) extensions
states three supported install methods, the first of which is exactly the shellexec
pattern the installer's plan wants:

> **"How users install your MCPB — Users can install three ways:**
> **1. Double-click** the `.mcpb` file
> **2. Drag and drop** the `.mcpb` file into the Claude Desktop window
> **3. Settings**: Settings → Extensions → Advanced settings → Install Extension… → select
> the `.mcpb` file
> All three open an installation UI where the user reviews extension details and
> permissions..."
> — [Anthropic, "Build a desktop extension with MCPB"](https://claude.com/docs/connectors/building/mcpb)

The same page's own Quickstart also states step 5 plainly as "Install and test in Claude
Desktop: **Double-click the generated `.mcpb` file.**" — i.e. Anthropic's own developer
workflow for testing a freshly-built bundle *is* double-click, the same action
`ShellExecute`/Inno's `shellexec` flag performs. The renaming notice for the format
confirms `.dxt` still works today, not just `.mcpb`:

> "If you're looking for the DXT tools, they have been renamed to MCPB... `.dxt` files are
> now `.mcpb` files" — alongside elsewhere-confirmed wording that "existing `.dxt`
> extensions will continue to work."
> — [github.com/anthropics/dxt](https://github.com/anthropics/dxt) (repository README, now
> redirecting to [modelcontextprotocol/mcpb](https://github.com/modelcontextprotocol/mcpb))

This is consistent with `.dxt`/`.mcpb` being registered as a Windows file type that opens
with Claude Desktop, the same shape as the existing `.fh_lua` pattern this repo's
installer already relies on (`installer\fh-mcp-bridge.iss`, `[Run]` section: `Filename:
"{app}\bridge\Claude MCP Bridge.fh_lua"; ... Flags: postinstall shellexec skipifsilent`,
lines 51–54, with the accompanying comment block explaining "shell-executing the .fh_lua
file... makes Family Historian offer to install it via its own native prompt").

**Confidence: high** that double-click/file-association-open is a real, currently
documented, Anthropic-endorsed install trigger — directly quoted from Anthropic's own
current docs, corroborated by their own internal developer-testing instructions using the
identical action.

### 2.2 CLI flags and the `claude://` URI scheme: no install trigger documented

Anthropic documents a `claude://` custom URI scheme for opening Claude Desktop to a
specific place:

> "Claude for macOS, Windows, and Linux respond to the `claude://` URL scheme... you can
> use these links... to open Claude Desktop and jump straight to a chat, a Cowork session,
> or a Code session."
> — [Claude Help Center, "Open Claude Desktop with a link"](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link)

The documented actions are: `claude://claude.ai/new` (new chat, with optional `q` prefill),
`claude://claude.ai/chat/{conversation-id}`, `claude://claude.ai/project/{project-id}`,
`claude://code/new`, and `claude://cowork/new`. **None of the documented `claude://` paths
is an extension-install action** — no `claude://extensions/install?...` or similar is
mentioned anywhere in this article. On Windows specifically, this URI scheme is registered
by the MSIX package's manifest (not classic `HKCR\claude\shell\open\command`):

> "On Windows, the MSIX package registers the `claude://` URI handler through its
> manifest's `windows.protocol` extension (URI Activation), not via a classic
> `shell\open\command` key."
> — search-result synthesis over the Help Center article; treat this specific
> implementation-detail sentence as **medium confidence**, since it came from a search
> engine's summarization layer rather than being independently re-quoted verbatim from a
> fetched primary page in this session — flagged for direct re-verification if it matters.

The official DXT/MCPB CLI (`@anthropic-ai/dxt`, now `@anthropic-ai/mcpb`) only documents
**build-side** commands, no install-side one:

> Commands documented: `init`, `validate`, `pack`, `sign`/`verify`/`unsign`, `info`. No
> `install` command, and no documented way to drive Claude's own install UI from a command
> line.
> — [github.com/anthropics/dxt, `CLI.md`](https://github.com/anthropics/dxt/blob/main/CLI.md)
> (now under [modelcontextprotocol/mcpb](https://github.com/modelcontextprotocol/mcpb/blob/main/CLI.md))

**Conclusion for this sub-question**: **the only confirmed programmatic trigger is
opening the `.dxt`/`.mcpb` file itself** (§2.1) — i.e. exactly the `.fh_lua`-shaped
shellexec pattern, not a CLI flag or URI scheme. No primary source documents any
"launch Claude and immediately show the extension-install dialog for file X" command-line
switch. **Confidence: high** that no such flag/URI action is publicly documented (absence
confirmed across the CLI reference, the MANIFEST spec, the engineering blog post, and the
dedicated "open Claude Desktop with a link" Help Center article — four independent
first-party documents, none of which mention it).

### 2.3 Known failure modes worth planning around

Two real bug reports show the double-click/file-open install path is not bulletproof in
practice, which the installer design should treat as a risk to handle gracefully (e.g. a
fallback message), not as a reason to doubt the mechanism exists:

> "**Local .mcpb install:** file picker accepts the file, but nothing happens at all (no
> error dialog, no log entry, no install)."
> — [anthropics/claude-code#67839](https://github.com/anthropics/claude-code/issues/67839)
> (Settings → Extensions → Install Extension… path, not double-click specifically, but the
> same underlying install handler)

> "The `installDxtFromDirectory` IPC handler never sends a reply when attempting to
> install the org-published connector... Log shows: `[MSIX] Filesystem virtualization
> active`... Bug is reproducible 100% with 1.12. It works in 1.11."
> — [anthropics/claude-code#68688](https://github.com/anthropics/claude-code/issues/68688)

These two reports are useful beyond just "it can fail" — the literal internal handler name
`installDxtFromDirectory` and the log line `"Installing unsigned extension from
...\dxt-download-*.mcpb"` (quoted in #68688) confirm Claude Desktop really does have a
single internal install code path that all three documented entry points (double-click,
drag-drop, Settings picker) funnel into — consistent with §2.1's claim that these are all
"the same mechanism," and consistent with `.fh_lua`'s own shellexec being just one more
way to invoke a single native install handler inside the target app, mirroring this
repo's own `.fh_lua` pattern conceptually. **Confidence: medium** on "these two bugs are
representative of general reliability," since two bug reports don't establish a failure
rate — flagged as a real risk to design a fallback for, not as proof the mechanism is
broken by default.

### 2.4 Cross-check against this repo's own `.fh_lua` pattern

`installer\fh-mcp-bridge.iss` already documents its own reasoning for *why* it shellexecs
`.fh_lua` rather than trying to place the file directly:

> "Deliberately does NOT try to detect FH's Plugins folder and copy the file there itself:
> shell-executing the `.fh_lua` file (the optional last step below) makes Family Historian
> offer to install it via its own native prompt, which handles that placement"
> (`fh-mcp-bridge.iss`, header comment, lines 16–20)

and implements it via a declarative `[Run]` entry with `Flags: postinstall shellexec
skipifsilent` (lines 51–54) — i.e. Inno Setup's own `shellexec` flag, which is
Inno-Setup's documented wrapper around exactly the OS file-association-open mechanism
`ShellExecute` provides. Given §2.1's confirmation that `.dxt`/`.mcpb` double-click is
Anthropic's own documented install trigger, **the `.fh_lua` pattern and the planned `.dxt`
pattern are the same mechanism at the OS level** — both rely on the target application
(FH, Claude Desktop) being registered as the default handler for a file extension, and
both hand off to that application's own native install/import UI rather than the installer
trying to place files itself. This is the strongest piece of evidence for issue #56's
plan being sound, but note it is **architecturally analogous, not independently
proven identical** — FH's own `.fh_lua` association mechanism was not itself re-verified
in this research pass (out of scope; the `.iss` file's own comment was taken as given
background per the ticket's framing), so "same pattern" here means "same OS-level
mechanism (file-type-association shellexec)," not "verified byte-for-byte identical
implementation."

**Confidence: high** that this is the right conceptual model (shellexec → OS file
association → target app's own install UI) for both `.fh_lua` and `.dxt`; **not
independently re-verified** that FH's `.fh_lua` association is itself a classic
`HKCR`-style registration (the `.iss` file's comment is taken as this repo's own existing,
presumably-tested knowledge, not re-derived here).

---

## 3. Summary table

| Question | Answer | Confidence | Confirmed / Unconfirmed |
|---|---|---|---|
| Two distinct Windows builds exist? | Yes — Squirrel (old) vs MSIX (new, Cowork-required) | High | Confirmed (§1.1) |
| Best install-time signal | `%LOCALAPPDATA%\AnthropicClaude\Claude.exe` existence, then `Get-AppxPackage -Name '*Claude*'` as fallback | Medium-high | Confirmed commands exist and are used in the wild (§1.3, §1.5); not run against a real machine in this research pass |
| Version-number threshold reliable? | No — numbering scheme itself changed at the Squirrel→MSIX boundary | High | Confirmed (§1.4) |
| Registry-key/marker-file unique to new build | Not confirmed by name | — | Unconfirmed (§4) |
| `.dxt`/`.mcpb` double-click opens Claude's install UI | Yes | High | Confirmed, direct Anthropic docs quote (§2.1) |
| CLI flag / `claude://` URI for extension install | Does not exist / not documented | High | Confirmed absence across 4 independent docs (§2.2) |
| `.fh_lua`-style shellexec is the right mechanism for `.dxt` | Yes, same OS-level mechanism | High (mechanism) / Medium (FH-side not re-verified) | Confirmed for Claude side (§2.1); FH side taken as given (§2.4) |

---

## 4. What remains unknown / needs verification on a real Windows machine

This research was documentation-and-issue-tracker-only — no PowerShell or Inno Setup code
was actually executed against a real Windows installation of either Claude Desktop
variant. The following are genuinely open and should be checked hands-on before Ticket C
is implemented, not assumed from this document:

1. **The exact `AppxPackage` object property name and format for the version string**
   returned by `Get-AppxPackage -Name '*Claude*'` (expected to be `.Version`, in
   `Major.Minor.Build.Revision` form per general Appx convention, but not independently
   confirmed against Claude's actual package output in this research pass).
2. **Whether `Get-AppxPackage -Name '*Claude*'` reliably matches** — the confirmed package
   family name is `Claude_pzs8sxrjxfjjc` ([#69353](https://github.com/anthropics/claude-code/issues/69353),
   [#83932](https://github.com/anthropics/claude-code/issues/83932)), but `-Name` in
   `Get-AppxPackage` matches the package's *Name* component, not the full family name with
   publisher hash — confirm `'*Claude*'` (or an exact `-Name Claude`) actually matches on a
   live machine rather than assuming it from the wildcard example in Anthropic's bug
   report ([#79307](https://github.com/anthropics/claude-code/issues/79307)), which used
   the wildcard for diagnosis, not as a hardened installer check.
3. **No confirmed registry uninstall-key name** for either build specific to Claude
   Desktop. General Squirrel.Windows framework behavior creates a per-user uninstall entry
   under `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<AppId>`
   ([Squirrel/Squirrel.Windows#1445](https://github.com/Squirrel/Squirrel.Windows/issues/1445)),
   and the Squirrel update-channel URL uses `id=AnthropicClaude`
   ([#25162](https://github.com/anthropics/claude-code/issues/25162)), suggesting the
   uninstall key is plausibly named `AnthropicClaude` — but this is **inference from
   adjacent facts, not a directly confirmed key name**, and MSIX packages don't use this
   uninstall-registry mechanism at all (they use `Get-AppxPackage`/`Get-Package` instead).
4. **No marker file/folder unique to the new build was found beyond the MSIX package
   registration itself** (i.e. no separate "flag file" Claude writes to signal "I am the
   unified app") — `Get-AppxPackage` is the only confirmed positive signal for the new
   build; the ticket's other candidate signals (marker file/folder) came up empty in this
   documentation-only pass.
5. **The `claude://` URI scheme's exact Windows registration mechanism** (MSIX
   `windows.protocol` manifest extension vs. classic registry) was only found via a search
   engine's synthesized summary, not independently re-quoted from a fetched primary page —
   worth a direct re-check of Anthropic's docs or the MSIX manifest itself if this detail
   ever becomes load-bearing for Ticket C (it currently isn't, since §2.2 concluded no
   `claude://` install action exists regardless of registration mechanism).
6. **Real end-to-end behavior of `ShellExecute`ing a `.dxt`/`.mcpb` file on an MSIX-packaged
   Claude Desktop** was not tested — §2.3's bug reports show the *Settings-picker* and
   *org-connector-download* install paths can fail silently on MSIX under some conditions;
   whether a plain double-click/shellexec-triggered open behaves any more or less reliably
   is unconfirmed.
7. **Whether "old-style Desktop that still honors `claude_desktop_config.json`" and
   "Squirrel-packaged Desktop" are exactly the same population** (§1.2) rests partly on
   issue #56's own reporter's investigation rather than an Anthropic statement — a
   Squirrel-build machine's actual `claude_desktop_config.json`-honoring behavior wasn't
   independently re-tested here.

Given all of the above, **the recommendation for Ticket C is to implement the §1.5 check
and §2.1 shellexec approach, but validate both against a real Squirrel-build machine and a
real MSIX-build machine before shipping** — this document narrows the design space and
gives working code sketches built from confirmed API signatures, but cannot substitute for
that hands-on validation pass.

---

## Sources

- This repo: `installer\fh-mcp-bridge.iss`, `installer\config-merge.ps1`,
  `docs\windows-installer-guide.md`, `docs\adr\0006-cite-every-fact-a-source-supports.md`,
  [issue #56](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/56),
  [issue #58](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/58)
- Anthropic first-party GitHub issues (`anthropics/claude-code`):
  [#79307](https://github.com/anthropics/claude-code/issues/79307),
  [#69353](https://github.com/anthropics/claude-code/issues/69353),
  [#83932](https://github.com/anthropics/claude-code/issues/83932),
  [#25162](https://github.com/anthropics/claude-code/issues/25162),
  [#40044](https://github.com/anthropics/claude-code/issues/40044),
  [#67839](https://github.com/anthropics/claude-code/issues/67839),
  [#68688](https://github.com/anthropics/claude-code/issues/68688)
- [Claude Desktop changelog](https://claude.com/docs/cowork/changelog) (Anthropic)
- [Claude Desktop third-party/managed configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration) (Anthropic)
- [Claude Help Center: "Open Claude Desktop with a link"](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link)
- [Claude Help Center: "Install Claude Desktop"](https://support.claude.com/en/articles/10065433-install-claude-desktop)
- [Claude Help Center: "Getting Started with Local MCP Servers on Claude Desktop"](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)
- [Anthropic: "Build a desktop extension with MCPB"](https://claude.com/docs/connectors/building/mcpb)
- [Anthropic engineering blog: "Desktop Extensions: One-click MCP server installation for Claude Desktop"](https://www.anthropic.com/engineering/desktop-extensions)
- [github.com/anthropics/dxt](https://github.com/anthropics/dxt) (README, `MANIFEST.md`, `CLI.md`; now redirects to [modelcontextprotocol/mcpb](https://github.com/modelcontextprotocol/mcpb))
- [Squirrel/Squirrel.Windows#1445](https://github.com/Squirrel/Squirrel.Windows/issues/1445) (general Squirrel.Windows uninstall-registry behavior, not Claude-specific)
- [jrsoftware.org — Inno Setup Pascal Script function reference](https://jrsoftware.org/ishelp/): [`GetVersionNumbers`](https://jrsoftware.org/ishelp/topic_isxfunc_getversionnumbers.htm), [`RegQueryStringValue`](https://jrsoftware.org/ishelp/topic_isxfunc_regquerystringvalue.htm), [`RegKeyExists`](https://jrsoftware.org/ishelp/topic_isxfunc_regkeyexists.htm), [`FileExists`](https://jrsoftware.org/ishelp/topic_isxfunc_fileexists.htm), [`DirExists`](https://jrsoftware.org/ishelp/topic_isxfunc_direxists.htm)
- [Microsoft Learn: `Get-AppxPackage` (Appx module)](https://learn.microsoft.com/en-us/powershell/module/appx/get-appxpackage)
- [Microsoft Learn: `FileVersionInfo.GetVersionInfo(String)` (System.Diagnostics)](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.fileversioninfo.getversioninfo)
