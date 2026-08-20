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
check("unknown file next starts at first", nav.adjacent_path(files, "/nope.ts", "next"), "/a.ts")
check("unknown file prev starts at last", nav.adjacent_path(files, "/nope.ts", "prev"), "/c.ts")
check("empty list", nav.adjacent_path({}, "/a.ts", "next"), nil)

check("porcelain modified", nav.porcelain_paths(" M foo.lua\0")[1], "foo.lua")
check("porcelain untracked", nav.porcelain_paths("?? bar.lua\0")[1], "bar.lua")
check("porcelain rename uses new name", nav.porcelain_paths("R  new.txt\0old.txt\0")[1], "new.txt")
check("porcelain copy uses new name", nav.porcelain_paths("C  copy.ts\0src.ts\0")[1], "copy.ts")

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

local first_hunk = { added = { start = 4, count = 2 }, vend = 5 }
local second_hunk = { added = { start = 20, count = 3 }, vend = 22 }
local delete_hunk = { added = { start = 40, count = 0 }, vend = 42 }
local ranged_hunks = { first_hunk, second_hunk, delete_hunk }
check("hunk at start line", nav.hunk_at(ranged_hunks, 4), first_hunk)
check("hunk at vend line", nav.hunk_at(ranged_hunks, 22), second_hunk)
check("hunk between hunks uses preceding", nav.hunk_at(ranged_hunks, 12), first_hunk)
check("hunk before first uses first", nav.hunk_at(ranged_hunks, 1), first_hunk)
check("pure-delete hunk at its line", nav.hunk_at(ranged_hunks, 40), delete_hunk)
check("empty hunk lookup", nav.hunk_at({}, 1), nil)
check("nil hunk lookup", nav.hunk_at(nil, 1), nil)

if fail > 0 then
  print(string.format("%d failed, %d passed", fail, pass))
  os.exit(1)
end
print(string.format("%d passed", pass))
