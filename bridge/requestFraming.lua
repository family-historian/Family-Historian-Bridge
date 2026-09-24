-- Parses a Bridge request's first line into a structured form the caller can act on.
-- Pure string parsing, no socket/FH dependency, so (unlike bridge.fh_lua's socket/IUP
-- plumbing) this is testable standalone.
--
-- Two LUA forms exist:
--   LUA <n>     -- run under the Session's own current Access mode (run_lua's own requests)
--   LUA_RO <n>  -- force the Read-only sandbox regardless of the Session's Access mode
--                  (describe_project's fixed script always uses this)
-- Both are followed by exactly n bytes: the script body, read separately by the caller.
-- STOP takes no byte-count and carries no script body.
-- VERSION <server-version> -- sent as its own connection ahead of every
--                             LUA/LUA_RO request, carrying the server's version so each
--                             side can compare it against its own (see versionCompare.lua
--                             and AI Assistant Connector.fh_lua's VERSION handling). Carries no
--                             separate body — the version travels in the header line.

local M = {}

-- Returns a table describing the parsed request, or nil if the header is malformed:
--   { kind = "stop" }
--   { kind = "lua", byteCount = <n>, forceReadOnly = <bool> }
function M.parse(header)
  if header:upper() == "STOP" then
    return { kind = "stop" }
  end

  local roCount = header:match("^LUA_RO (%d+)$")
  if roCount then
    return { kind = "lua", byteCount = tonumber(roCount), forceReadOnly = true }
  end

  local count = header:match("^LUA (%d+)$")
  if count then
    return { kind = "lua", byteCount = tonumber(count), forceReadOnly = false }
  end

  local serverVersion = header:match("^VERSION (%S+)$")
  if serverVersion then
    return { kind = "version", serverVersion = serverVersion }
  end

  return nil
end

-- Resolves the access mode a parsed "lua" request should actually run under: a forced
-- Read-only request always wins over the Session's own current Access mode -- this is the
-- one line that decides whether describe_project's forcing form actually forces anything.
function M.resolveAccessMode(request, currentAccessMode)
  if request.forceReadOnly then
    return "read-only"
  end
  return currentAccessMode
end

return M
