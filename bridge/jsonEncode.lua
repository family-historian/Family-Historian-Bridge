-- Minimal JSON encoder for values returned by a run_lua script.
-- FH's Lua (5.3) ships no JSON library, so this is hand-rolled rather than a dependency.
-- See CONTEXT.md "run_lua" and docs/adr/0001-arbitrary-sandboxed-lua-execution.md.

local M = {}

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
  ['\b'] = '\\b', ['\f'] = '\\f',
}

local function encodeString(s)
  local out = s:gsub('[%c\\"]', function(c)
    return escapes[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. out .. '"'
end

-- A table encodes as a JSON array only when its keys are exactly 1..n with no gaps.
-- An empty table has no way to signal "array" vs "object" from its keys alone, so it
-- encodes as an empty object ({}) — the same default most JSON libraries pick.
local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encodeValue

local function encodeArray(t)
  local parts = {}
  for i = 1, #t do
    parts[i] = encodeValue(t[i])
  end
  return '[' .. table.concat(parts, ',') .. ']'
end

local function encodeObject(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts + 1] = encodeString(tostring(k)) .. ':' .. encodeValue(v)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

encodeValue = function(value)
  local t = type(value)
  if value == nil then
    return 'null'
  elseif t == 'boolean' then
    return value and 'true' or 'false'
  elseif t == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then
      error('cannot encode non-finite number to JSON')
    end
    return tostring(value)
  elseif t == 'string' then
    return encodeString(value)
  elseif t == 'table' then
    if isArray(value) then
      return encodeArray(value)
    else
      return encodeObject(value)
    end
  else
    error('cannot encode value of type ' .. t .. ' to JSON')
  end
end

function M.encode(value)
  return encodeValue(value)
end

return M
