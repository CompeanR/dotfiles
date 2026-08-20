-- Runnable with: nvim -l tests/nvim_review_mode_test.lua
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/") or "."
package.path = root .. "/nvim/lua/?.lua;" .. package.path

local review = require("config.review_mode")

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

check("nil target uses default rev", review.parse_target(nil).rev, "origin/master")
check("empty target uses default rev", review.parse_target("").rev, "origin/master")
check("digits target is PR", review.parse_target("110").pr, 110)
check("origin branch target is rev", review.parse_target("origin/master").rev, "origin/master")
check("hex-looking target with letters is rev", review.parse_target("abc123def").rev, "abc123def")
check("default state is inactive", review.is_active(), false)
check("default status is empty", review.status(), "")

if fail > 0 then
  print(string.format("%d failed, %d passed", fail, pass))
  os.exit(1)
end
print(string.format("%d passed", pass))
