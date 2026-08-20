-- Shared assertion/report helpers for the standalone bridge/tests/*.test.lua files (no FH/socket
-- dependency, each run as its own `lua ...` process via scripts/run-bridge-tests.mjs). new()
-- returns a fresh {check, contains, report} triple per file so failure counts never leak between
-- test files sharing this module.

local M = {}

function M.new(opts)
  opts = opts or {}
  local passFmt = opts.passFmt or 'PASS %s'
  local failFmt = opts.failFmt or 'FAIL %s'
  local failures = 0

  local function check(condition, label)
    if condition then
      print(string.format(passFmt, label))
    else
      failures = failures + 1
      print(string.format(failFmt, label))
    end
  end

  local function contains(haystack, needle)
    return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
  end

  -- Prints the pass/fail summary and exits with the process code scripts/run-bridge-tests.mjs
  -- checks (0 = all assertions passed, 1 = at least one failed).
  local function report()
    if failures > 0 then
      print(string.format('\n%d assertion(s) failed', failures))
      os.exit(1)
    else
      print('\nAll assertions passed')
      os.exit(0)
    end
  end

  return { check = check, contains = contains, report = report }
end

return M
