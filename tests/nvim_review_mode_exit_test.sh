#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
outside=$(mktemp -d)
cleanup() {
  rm -rf "$tmp" "$outside"
}
trap cleanup EXIT

printf 'outside review repository\n' > "$outside/outside.txt"

cd "$tmp"
git init -q
git config user.email "review-mode-test@example.com"
git config user.name "Review Mode Test"
for i in $(seq 1 40); do
  printf 'local line_%02d = %d\n' "$i" "$i"
done > main.lua
git add main.lua
git commit -qm "initial"
branch=$(git branch --show-current)
if [[ -n "$branch" ]]; then
  printf 'ok - detected initial branch %s\n' "$branch"
else
  printf 'not ok - could not detect initial branch\n'
  exit 1
fi

sed -i '20s/.*/local line_20 = "reviewed"/' main.lua
git add main.lua
git commit -qm "review change"
sed -i '29s/.*/local line_29 = "WIP"/' main.lua

printf '\n# stash recovery contract\n'
cat > .git/review_stash_stop_test.lua <<'LUA'
local failed = false

local function report(name, ok)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name)
  end
end

local function git(...)
  return vim.system({ "git", ... }, { text = true }):wait()
end

require("config.review_mode").start("HEAD~1", { stash = true })
report("stash opt-in leaves the work tree clean", git("status", "--porcelain").stdout == "")
report("stash opt-in records the review stash", (git("stash", "list").stdout or ""):find("nvim review mode", 1, true) ~= nil)

vim.cmd.edit(assert(os.getenv("REVIEW_OUTSIDE")) .. "/outside.txt")
vim.cmd("ReviewStop")
report("ReviewStop restores the WIP change", vim.fn.readfile("main.lua")[29] == 'local line_29 = "WIP"')
report("ReviewStop leaves the restored work tree dirty", git("status", "--porcelain").stdout ~= "")
report("ReviewStop removes the review stash", git("stash", "list").stdout == "")

if failed then vim.cmd("cquit") end
LUA

REVIEW_OUTSIDE="$outside" nvim --headless "+cd $tmp" "+edit main.lua" \
  "+luafile $tmp/.git/review_stash_stop_test.lua" "+qa!"

cat > .git/review_autocmd_test.lua <<'LUA'
local failed = false

local function report(name, ok)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name)
  end
end

vim.cmd("ReviewStart HEAD")
local group_exists, leave = pcall(vim.api.nvim_get_autocmds, {
  group = "review_mode",
  event = "VimLeavePre",
})
report("ReviewStart registers VimLeavePre restore", group_exists and #leave == 1)

vim.cmd("ReviewStop")
local group_exists, after_stop = pcall(vim.api.nvim_get_autocmds, {
  group = "review_mode",
  event = "VimLeavePre",
})
report("ReviewStop removes VimLeavePre restore", not group_exists or #after_stop == 0)

if failed then vim.cmd("cquit") end
LUA

nvim --headless "+cd $tmp" "+edit main.lua" \
  "+luafile $tmp/.git/review_autocmd_test.lua" "+qa!"
printf '\n'

marker="$tmp/.git/review_exit_marker"
cat > .git/review_exit_active_test.lua <<'LUA'
local review = require("config.review_mode")
review.start("HEAD~1", { stash = true })
local clean = vim.system({ "git", "status", "--porcelain" }, { text = true }):wait().stdout == ""
local stashed = (vim.system({ "git", "stash", "list" }, { text = true }):wait().stdout or ""):find("nvim review mode", 1, true) ~= nil
local group_exists, leave = pcall(vim.api.nvim_get_autocmds, {
  group = "review_mode",
  event = "VimLeavePre",
})
if not review.is_active() or not clean or not stashed or not group_exists or #leave ~= 1 then
  print("not ok - review stash restore is not registered before exit")
  vim.cmd("cquit")
end
print("ok - stash opt-in is active and clean before +qa!")
vim.cmd.edit(assert(os.getenv("REVIEW_OUTSIDE")) .. "/outside.txt")

vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    local restore = vim.api.nvim_get_autocmds({ group = "review_mode", event = "VimLeavePre" })
    local marker = assert(os.getenv("REVIEW_EXIT_MARKER"))
    local observed = review.is_active() and #restore == 1
    vim.fn.writefile({ observed and "observed" or "missing" }, marker)
  end,
})
LUA

REVIEW_EXIT_MARKER="$marker" REVIEW_OUTSIDE="$outside" nvim --headless "+cd $tmp" "+edit main.lua" \
  "+luafile $tmp/.git/review_exit_active_test.lua" "+qa!"

if [[ -f "$marker" ]] && [[ "$(<"$marker")" == "observed" ]]; then
  printf 'ok - +qa! dispatches VimLeavePre with the review restore registered\n'
else
  printf 'not ok - +qa! did not dispatch VimLeavePre with the review restore registered\n'
  exit 1
fi

if grep -q '^local line_29 = "WIP"$' main.lua && [[ -n "$(git status --porcelain)" ]] && [[ -z "$(git stash list)" ]]; then
  printf 'ok - +qa! restores the WIP change and removes the review stash\n'
else
  printf 'not ok - +qa! did not restore the WIP change cleanly\n'
  exit 1
fi

printf '\nok - review mode exit regression\n'
