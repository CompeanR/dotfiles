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
printf 'local value = 1\n' > main.lua
git add main.lua
git commit -qm "initial"
printf 'local value = 2\n' > main.lua
printf 'local other = 1\n' > other.lua
git add other.lua
git commit -qm "second file"
printf 'local other = 2\n' > other.lua

cat > .git/review_keymaps_test.lua <<'LUA'
local failed = false
local expected = {
  "<C-i>",
  "<C-n>",
  "<C-p>",
  "<C-q>",
  "<S-Tab>",
  "<Tab>",
  "<leader>rd",
  "<leader>rp",
  "<leader>rq",
  "[f",
  "]f",
}
local forbidden = { "a", "d", "p", "e", "q", "n", "N", "H", "L", "K", "gh", "<CR>", "<BS>" }

local function report(name, ok, detail)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function normalize(lhs)
  local leader = vim.g.mapleader or "\\"
  if lhs:sub(1, #leader) == leader then lhs = "<leader>" .. lhs:sub(#leader + 1) end
  return lhs:gsub("<C%-([A-Z])>", function(key) return "<C-" .. key:lower() .. ">" end)
end

local function review_maps()
  local maps = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if map.desc and map.desc:match("^review: ") then maps[#maps + 1] = normalize(map.lhs) end
  end
  table.sort(maps)
  return maps
end

vim.cmd("ReviewStart HEAD")
local function current_name() return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") end
report("focus returns to the file window after start", vim.bo.filetype ~= "neo-tree" and current_name() ~= "", vim.bo.filetype .. " " .. current_name())
local first = current_name()
local first_buf = vim.api.nvim_get_current_buf()
vim.wait(3000, function() return false end)
local function has_review_map(buf)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc and map.desc:match("^review: ") and normalize(map.lhs) == "]f" then return true end
  end
  return false
end
report("first file keeps review keymaps after settling", vim.api.nvim_buf_is_valid(first_buf) and has_review_map(first_buf))
report("still on the first file after settling", current_name() == first and vim.bo.filetype ~= "neo-tree", current_name())
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("]f", true, false, true), "x", false)
vim.wait(1000, function() return current_name() ~= first end)
report("]f moves to the next changed file", current_name() ~= first and current_name() ~= "", current_name())
vim.cmd("buffer " .. first_buf)
local actual = review_maps()
report("review keymaps include hunk, file, and commit-review keys", vim.deep_equal(actual, expected), "got " .. vim.inspect(actual))

local tab = vim.fn.maparg("<Tab>", "n", false, true)
local ci = vim.fn.maparg("<C-i>", "n", false, true)
report("Tab is next hunk", type(tab) == "table" and tab.desc == "review: next hunk", vim.inspect(tab))
report("C-i is jumplist forward", type(ci) == "table" and ci.desc == "review: jumplist forward", vim.inspect(ci))
report(
  "Tab and C-i use distinct lhsraw",
  type(tab) == "table"
    and type(ci) == "table"
    and type(tab.lhsraw) == "string"
    and type(ci.lhsraw) == "string"
    and tab.lhsraw ~= ci.lhsraw,
  vim.inspect({ tab = tab.lhsraw, ci = ci.lhsraw })
)
report("Tab still wins the tab byte", type(tab) == "table" and tab.lhsraw == "\t", vim.inspect(tab.lhsraw))

for _, lhs in ipairs(forbidden) do
  local map = vim.fn.maparg(lhs, "n", false, true)
  local is_review = type(map) == "table" and type(map.desc) == "string" and map.desc:match("^review: ") ~= nil
  report(lhs .. " is not mapped by review mode", not is_review)
end

vim.cmd("ReviewStop")
local remaining = review_maps()
report("ReviewStop removes every review keymap", #remaining == 0, "got " .. vim.inspect(remaining))

if failed then vim.cmd("cquit") end
LUA

nvim --headless "+cd $tmp" "+edit main.lua" \
  "+luafile $tmp/.git/review_keymaps_test.lua" "+qa!"

printf '\nok - review mode keymap contract\n'
