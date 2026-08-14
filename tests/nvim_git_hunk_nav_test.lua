-- Runnable with: nvim -l tests/nvim_git_hunk_nav_test.lua
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/") or "."
package.path = root .. "/nvim/lua/?.lua;" .. package.path

local nav = require("config.git_hunk_nav")

local pass, fail = 0, 0

local function check(name, got, want)
  if got == want then
    pass = pass + 1
    print("ok - " .. name)
  else
    fail = fail + 1
    print(string.format("not ok - %s\n  want: %s\n  got:  %s", name, tostring(want), tostring(got)))
  end
end

local files = { "/a.ts", "/b.ts", "/c.ts" }
check("next from first file", nav.adjacent_path(files, "/a.ts", "next"), "/b.ts")
check("next from last file", nav.adjacent_path(files, "/c.ts", "next"), nil)
check("prev from last file", nav.adjacent_path(files, "/c.ts", "prev"), "/b.ts")
check("prev from first file", nav.adjacent_path(files, "/a.ts", "prev"), nil)
check("unknown file", nav.adjacent_path(files, "/nope.ts", "next"), nil)

local hunks = {
  { added = { start = 4, count = 2 } },
  { added = { start = 20, count = 1 } },
  { added = { start = 40, count = 3 } },
}
check("next hunk exists before last", nav.has_hunk(hunks, 4, "next", 80), true)
check("no next hunk on last", nav.has_hunk(hunks, 40, "next", 80), false)
check("no next hunk inside last", nav.has_hunk(hunks, 42, "next", 80), false)
check("prev hunk exists after first", nav.has_hunk(hunks, 20, "prev", 80), true)
check("no prev hunk on first", nav.has_hunk(hunks, 4, "prev", 80), false)
check("no hunks", nav.has_hunk({}, 1, "next", 10), false)
check("nil hunks", nav.has_hunk(nil, 1, "next", 10), false)

local eof_delete = { { added = { start = 11, count = 0 } } }
check("eof delete on last line is last hunk", nav.has_hunk(eof_delete, 10, "next", 10), false)
check("eof delete has next from earlier line", nav.has_hunk(eof_delete, 3, "next", 10), true)

if fail > 0 then
  print(string.format("%d failed, %d passed", fail, pass))
  os.exit(1)
end
print(string.format("%d passed", pass))
