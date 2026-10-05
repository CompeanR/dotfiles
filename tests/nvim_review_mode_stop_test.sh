#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cd "$tmp"
git init -q
git config user.email "review-mode-test@example.com"
git config user.name "Review Mode Test"
printf 'local keep = 1\n' > keep.lua
git add keep.lua
git commit -qm "initial"
git checkout -qb feat
printf 'local added = 1\n' > added.lua
printf 'local added_two = 1\n' > added_two.lua
git add added.lua added_two.lua
git commit -qm "add files"
sha=$(git rev-parse HEAD)
git checkout -q -

cat > .git/review_stop_test.lua <<'LUA'
local failed = false
local sha = assert(os.getenv("REVIEW_SHA"))

local function report(name, ok, detail)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name .. (detail and (": " .. detail) or ""))
  end
end

local notifications = {}
local original_notify = vim.notify
vim.notify = function(msg, level, ...)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then notifications[#notifications + 1] = tostring(msg) end
  return original_notify(msg, level, ...)
end

local function buf_for(name)
  return vim.fn.bufnr(vim.fn.fnamemodify(name, ":p"))
end

require("config.review_mode").start_commit(sha)
vim.wait(1000, function() return false end)

vim.cmd("edit added.lua")
vim.cmd("edit added_two.lua")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- unsaved edit" })
vim.cmd("edit keep.lua")
local clean, dirty, keep = buf_for("added.lua"), buf_for("added_two.lua"), buf_for("keep.lua")
report("setup loaded the added buffers", clean > 0 and dirty > 0 and vim.bo[dirty].modified)

vim.wait(1000, function() return false end)
vim.v.errmsg = ""
vim.cmd("ReviewStop")
vim.wait(2000, function() return false end)

report("ReviewStop returns to the original branch", vim.trim(vim.fn.system("git rev-parse --abbrev-ref HEAD")) == "master" or vim.trim(vim.fn.system("git rev-parse --abbrev-ref HEAD")) == "main")
report("unmodified vanished buffer is deleted", not vim.api.nvim_buf_is_valid(clean) or not vim.api.nvim_buf_is_loaded(clean))
report("modified vanished buffer is kept", vim.api.nvim_buf_is_valid(dirty) and vim.api.nvim_buf_is_loaded(dirty) and vim.bo[dirty].modified)
report("existing file buffer is kept", vim.api.nvim_buf_is_valid(keep) and vim.api.nvim_buf_is_loaded(keep))
report("v:errmsg stays empty", vim.v.errmsg == "", vim.v.errmsg)
report("no warnings or errors were notified", #notifications == 0, vim.inspect(notifications))

if failed then vim.cmd("cquit") end
LUA

REVIEW_SHA=$sha nvim --headless "+cd $tmp" "+edit keep.lua" \
  "+luafile $tmp/.git/review_stop_test.lua" "+qa!"

printf '\nok - review stop drops vanished buffers\n'
