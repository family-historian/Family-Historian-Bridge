-- Locale-independent UTF-8 lowercasing. string.lower/upper and the %c/%a/%u/%l pattern
-- classes follow the C library locale, so under e.g. cp1250 they miss non-ASCII capitals
-- (Ę) and can misclassify UTF-8 continuation bytes. Covers ASCII, Latin-1, Latin
-- Extended-A/Additional, Greek and Cyrillic; other code points and invalid bytes pass
-- through untouched.

local M = {}

local function foldCodepoint(cp)
  if cp < 0x80 then
    if cp >= 0x41 and cp <= 0x5A then return cp + 32 end
    return cp
  end
  if cp >= 0xC0 and cp <= 0xDE then
    if cp == 0xD7 then return cp end
    return cp + 32
  end
  if cp >= 0x100 and cp <= 0x17F then
    if cp == 0x130 or cp == 0x138 or cp == 0x149 or cp == 0x17F then return cp end
    if cp == 0x178 then return 0xFF end
    if (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
      if cp % 2 == 1 then return cp + 1 end
      return cp
    end
    if cp % 2 == 0 then return cp + 1 end
    return cp
  end
  if cp >= 0x1E00 and cp <= 0x1EFF then
    if cp == 0x1E9E then return 0xDF end
    if cp >= 0x1E96 and cp <= 0x1E9F then return cp end
    if cp % 2 == 0 then return cp + 1 end
    return cp
  end
  if cp >= 0x386 and cp <= 0x3AB then
    if cp == 0x386 then return 0x3AC end
    if cp >= 0x388 and cp <= 0x38A then return cp + 37 end
    if cp == 0x38C then return 0x3CC end
    if cp == 0x38E or cp == 0x38F then return cp + 63 end
    if cp >= 0x391 and cp <= 0x3AB and cp ~= 0x3A2 then return cp + 32 end
    return cp
  end
  if cp >= 0x400 and cp <= 0x52F then
    if cp <= 0x40F then return cp + 80 end
    if cp <= 0x42F then return cp + 32 end
    if cp >= 0x460 and cp <= 0x481 then
      if cp % 2 == 0 then return cp + 1 end
      return cp
    end
    if cp >= 0x48A and cp <= 0x4BF then
      if cp % 2 == 0 then return cp + 1 end
      return cp
    end
    if cp == 0x4C0 then return 0x4CF end
    if cp >= 0x4C1 and cp <= 0x4CE then
      if cp % 2 == 1 then return cp + 1 end
      return cp
    end
    if cp >= 0x4D0 then
      if cp % 2 == 0 then return cp + 1 end
      return cp
    end
  end
  return cp
end

-- utf8.charpattern lets a continuation-byte run glue onto a preceding ASCII byte, so
-- ASCII is folded separately from multi-byte sequences.
function M.lower(s)
  s = tostring(s)
  local out = s:gsub("[A-Z]", function(c)
    return string.char(c:byte() + 32)
  end)
  out = out:gsub("[\xC2-\xFD][\x80-\xBF]*", function(ch)
    if not utf8.len(ch) then return nil end
    local cp = utf8.codepoint(ch)
    local folded = foldCodepoint(cp)
    if folded == cp then return nil end
    return utf8.char(folded)
  end)
  return out
end

return M
