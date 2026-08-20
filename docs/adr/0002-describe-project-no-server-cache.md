# describe_project recomputes on every call; no server-side cache

`describe_project` (issue #10) walks every record to build record-type counts and a
distinct-tag census. The MCP server process's lifetime does not map 1:1 to a Bridge
Session's lifetime, `run_lua` opens a fresh TCP socket per call with no session token,
and the server (started by the MCP host over stdio) can outlive a Stop/Start cycle into a
different FH project entirely. A naive process-lifetime cache would silently serve a
stale census after the user switches projects.

We decided not to cache at all, rather than key a cache off project identity (e.g.
`fhGetContextInfo("CI_PROJECT_FILE")`). `describe_project` is a look-once-at-the-start
tool, a Claude conversation calling it more than once or twice is the rare case, so the
redundant recomputation this accepts is cheap relative to the invalidation logic avoided.
