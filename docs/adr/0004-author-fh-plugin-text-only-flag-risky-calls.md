# author_fh_plugin returns text only, and flags risky function calls inline

`author_fh_plugin` (issue #9) generates a standalone FH Report/Query plugin the user
installs themselves, deliberately outside `run_lua`'s sandboxed trust boundary, so it can
use functions the sandbox excludes (`fhShellExecute`, filesystem functions,
`fhMessageBox`, `fhPromptUserFor*`). That freedom is only safe if the user genuinely
reviews the plugin before installing it, which is a weaker checkpoint than reviewing an
inline chat answer, a plugin file is easy to skim past or trust on the strength of "an AI
wrote this for me."

Two decisions follow from that:

1. The tool never writes the generated file to disk itself, it returns the plugin as text
   for the user to save manually. Writing it out would mean this server touches the
   filesystem in service of code that's about to escape its own trust boundary entirely;
   keeping it text-only keeps the save step a deliberate, visible action rather than
   something that already happened by the time the user notices.
2. Any use of a function `run_lua`'s sandbox would have excluded is flagged inline in the
   generated output, not left for the user to notice by reading the whole script
   themselves.
