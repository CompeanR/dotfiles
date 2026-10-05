#!/usr/bin/env bash
# Review history of nvim/lua/config/review_pr.lua: gR goes to the most recent
# reviewed PR other than the one under review, per repo, capped at 5, and
# survives missing, corrupt or wrong-shape history. review_mode is stubbed.
set -euo pipefail

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

for repo in one two; do
  mkdir "$tmp/$repo"
  git -C "$tmp/$repo" init -q
done

cat > "$tmp/test.lua" <<'LUA'
local tmp = vim.env.TMP_DIR
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end

local started, current = {}, nil
package.loaded["config.review_mode"] = {
  start = function(arg)
    started[#started + 1] = tonumber(arg)
    current = tonumber(arg)
  end,
  is_active = function() return current ~= nil end,
  pr = function() return current end,
}

local review = require("config.review_pr")
local history_path = vim.fn.stdpath("state") .. "/review_pr_history.json"
vim.fn.mkdir(vim.fn.stdpath("state"), "p")

local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\nnotes: " .. vim.inspect(notes) .. "\nstarted: " .. vim.inspect(started) .. "\n")
    vim.cmd("cquit 1")
  end
end

local function reset(content)
  started, notes, current = {}, {}, nil
  os.remove(history_path)
  if content then vim.fn.writefile({ content }, history_path) end
end

local function open(repo)
  vim.fn.chdir(tmp .. "/" .. repo)
  return vim.uv.cwd()
end

local function visit(dir, number)
  review.review(dir, { number = number, baseRefName = "master", title = "PR " .. number })
end

local function last() review.review_last() end

local one = open("one")

for _, content in ipairs({ false, "", "not json", "[1,2]", '"text"', '{"' .. one .. '": 5}', '{"' .. one .. '": {"a": 1}}', '{"' .. one .. '": ["x", 7, {"title": "no number"}]}' }) do
  reset(content)
  last()
  expect(#started == 0 and notes[1] == "No other reviewed PR in this repo", "no other PR for history " .. tostring(content))
end

reset('{"' .. one .. '": ["x", {"title": "no number"}]}')
visit(one, 10)
local stored = vim.json.decode(table.concat(vim.fn.readfile(history_path), "\n"))
expect(#stored[one] == 1 and stored[one][1].number == 10, "wrong-shape entries dropped when remembering")

reset()
visit(one, 1)
visit(one, 2)
started = {}
last()
expect(vim.deep_equal(started, { 1 }), "gR from B goes to A: " .. vim.inspect(started))
last()
expect(vim.deep_equal(started, { 1, 2 }), "gR from A goes back to B: " .. vim.inspect(started))

reset()
visit(one, 1)
visit(one, 2)
current = nil
started = {}
last()
expect(vim.deep_equal(started, { 2 }), "non-PR review goes to the most recent PR: " .. vim.inspect(started))

reset()
visit(one, 1)
current = nil
started = {}
last()
expect(vim.deep_equal(started, { 1 }), "single PR reachable after a non-PR review")
last()
expect(#started == 1 and notes[#notes] == "No other reviewed PR in this repo", "only the current PR left")

reset()
for _, number in ipairs({ 1, 2, 3, 2, 4, 5, 6, 7 }) do visit(one, number) end
local numbers = vim.tbl_map(function(entry) return entry.number end, vim.json.decode(table.concat(vim.fn.readfile(history_path), "\n"))[one])
expect(vim.deep_equal(numbers, { 7, 6, 5, 4, 2 }), "dedupe and cap 5: " .. vim.inspect(numbers))

reset()
local two = open("two")
visit(one, 1)
visit(two, 9)
started = {}
current = nil
last()
expect(vim.deep_equal(started, { 9 }), "repo two sees its own history: " .. vim.inspect(started))
open("one")
current = nil
last()
expect(vim.deep_equal(started, { 9, 1 }), "repo one sees its own history: " .. vim.inspect(started))
local both = vim.json.decode(table.concat(vim.fn.readfile(history_path), "\n"))
expect(#both[one] == 1 and #both[two] == 1, "histories stay separate")

print("ok")
vim.cmd("qa!")
LUA

TMP_DIR="$tmp" XDG_STATE_HOME="$tmp/state" nvim --headless -u NONE -i NONE \
  "+set rtp+=$PWD/nvim" "+luafile $tmp/test.lua" 2>&1
