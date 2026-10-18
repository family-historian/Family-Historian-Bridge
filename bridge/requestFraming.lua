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
--                             and AI Connector.fh_lua's VERSION handling). Carries no
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

  -- "LUA <n>" optionally followed by " assistant=<percent-encoded name>" -- the server's
  -- name for the calling AI assistant, used for the session log's title. Absent from older
  -- servers and run_lua calls with no known assistant.
  local count, assistant = header:match("^LUA (%d+) assistant=(%S*)$")
  if not count then
    count = header:match("^LUA (%d+)$")
  end
  if count then
    return {
      kind = "lua",
      byteCount = tonumber(count),
      forceReadOnly = false,
      assistant = M.decodeAssistant(assistant),
    }
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

-- requestFraming.decodeAssistant(encoded)
-- Percent-decodes the header's assistant name, then re-sanitises it (control characters to
-- spaces, whitespace collapsed, trimmed, capped at 40 chars) so a non-conforming server
-- can't inject anything into the note. Returns nil for nil/empty input.
function M.decodeAssistant(encoded)
  if not encoded or encoded == "" then
    return nil
  end
  local decoded = encoded:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  decoded = decoded:gsub("[\0-\31\127]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #decoded > 40 then
    decoded = decoded:sub(1, 40):gsub(" $", "")
  end
  if decoded == "" then
    return nil
  end
  return decoded
end

return M
