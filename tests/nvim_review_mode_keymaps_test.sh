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

cat > .git/review_keymaps_test.lua <<'LUA'
local failed = false
local expected = {
  "<C-n>",
  "<C-p>",
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
local actual = review_maps()
report("review keymaps are exactly the nine-key contract", vim.deep_equal(actual, expected), "got " .. vim.inspect(actual))

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
