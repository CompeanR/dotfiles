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
check("inactive review has no commit range", review.git_log_range(nil), nil)
check("empty sha has no commit range", review.git_log_range(""), nil)
check("review commits are exclusive from the merge-base", review.git_log_range("abc1234"), "abc1234..HEAD")
check("git log line yields sha", review.git_log_sha("a1b2c3d (2 hours ago) fix login"), "a1b2c3d")
check("git log sha ignores leading space", review.git_log_sha("  deadbeef extra"), "deadbeef")
check("empty git log line has no sha", review.git_log_sha(""), nil)
check("nil git log line has no sha", review.git_log_sha(nil), nil)
check("plain message is not a sha", review.git_log_sha("fix the login prompt"), nil)
local spec = review.commit_review("a1b2c3d")
check("commit review uses parent as base", spec and spec.rev, "a1b2c3d^")
check("commit review checkouts that commit", spec and spec.checkout, "a1b2c3d")
check("empty commit review is nil", review.commit_review(""), nil)

if fail > 0 then
  print(string.format("%d failed, %d passed", fail, pass))
  os.exit(1)
end
print(string.format("%d passed", pass))
