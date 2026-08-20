# install_fh_plugin writes to FH's Plugins folder directly, but only on explicit request

`install_fh_plugin` (issue #24) exists alongside `author_fh_plugin`, not as a replacement
for it. ADR 0004 keeps `author_fh_plugin` itself text-only specifically because installing
a plugin is a weaker review checkpoint than reading a chat answer, and that reasoning is
unaffected by anything below, a generated plugin can still legitimately call functions
`run_lua`'s sandbox excludes (`fhShellExecute`, filesystem functions, `fhMessageBox`, ...),
flagged inline for review.

What issue #24 asked for was removing the *mechanical* friction of that review step,
saving the returned text to a file yourself, finding FH's Plugins folder, and renaming it
by hand each time you iterate, not removing the review step itself. Four decisions follow:

1. **Staged, not automatic.** `install_fh_plugin` is a second, separate tool call, made
   only when the user explicitly asks to install what was just generated. It is never
   chained onto `author_fh_plugin` automatically, even when the generated plugin has no
   `-- FLAGGED` lines, the user still has to look at the plugin and decide to trust it,
   the same deliberate gesture ADR 0004 protects, just without the extra manual save step
   once they've decided.
2. **Stateless.** The tool takes the plugin source as an explicit input parameter, the same
   way `run_lua` has no server-side script state, Claude passes back what it generated (or
   what the user asked it to tweak), rather than the server trusting a cached "last
   generated plugin" that could silently be stale.
3. **The Node server writes the file directly**, not the Bridge/Lua side. The server
   already runs on the same machine as FH (see docs/user-guide.md's install steps) and can
   use `fs` directly, a completely separate trust boundary from `run_lua`'s sandboxed Lua
   execution, so this needs no change to `bridge/sandbox.lua`'s excluded-function list.
   `fhSaveTextFile` and friends stay excluded from `run_lua` exactly as before; this is a
   new, unrelated write path that a live Lua script can never reach.
4. **The Plugins folder location is resolved live**, via `fhGetContextInfo("CI_APP_DATA_FOLDER")`
   (already unrestricted in the sandbox) plus `\Plugins`, rather than guessed from the OS.
   docs/user-guide.md already documents a real footgun here, FH7 and FH8 keep separate
   Plugins folders side by side, "easy to copy into by mistake, and FH won't tell you if you
   do", and a live query against whichever FH the user actually has a Session open in
   sidesteps that entirely. When no Session is running, the tool falls back to an explicit
   `path` parameter that Claude fills in only after asking the user to confirm it themselves.

Naming: never overwrites. Each install gets the next unused `V<N>` suffix on both the
filename and the plugin's own `@Title` header (not just the filename), so FH's own Tools ->
Plugins list disambiguates repeated installs of the same plugin as well as the files on
disk do.

5. **Always written as UTF-8 with a BOM.** Confirmed live (via `describe_project`'s
   `contextInfo.CI_STRING_ENCODING`) that a plugin file with no encoding marker loads into
   FH as ANSI, even though FH's own Plugin Editor defaults new plugins to UTF-8 from
   version 6 onwards (FH help: "String Encoding and Unicode"). ANSI silently mangles any
   accented/non-ASCII text a script reads from or writes to the tree, a genealogy tool's
   data is exactly the kind of text this bites hardest. `handleInstallFhPlugin` prepends
   the UTF-8 BOM (`U+FEFF`) to every file it writes, which FH's own file-encoding
   detection looks for (confirmed via fhug.org.uk's `TestEncoding()` snippet checking for
   the `EF BB BF` byte sequence). `author_fh_plugin`'s own footer, for the manual-save path
   this tool doesn't cover, tells the user to save as UTF-8 themselves.

Out of scope for this tool: triggering FH's own plugin-registration step (double-click /
Tools -> Plugins -> Import) after writing the file. That would mean the server executing a
file it just wrote via the OS shell, a meaningfully bigger capability than writing one,
for a convenience win that only saves one dialog click either way. `install_fh_plugin`'s
response instead reminds the user to close and reopen the Plugins Dialog if it's open,
since FH doesn't rescan the folder live; a proper refresh button has been raised with
Calico Pie as issue #27.
