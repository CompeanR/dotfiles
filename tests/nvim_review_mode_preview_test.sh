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
for i in $(seq 1 60); do
  printf 'local line_%02d = %d\n' "$i" "$i"
done > main.lua
git add main.lua
git commit -qm "initial"
awk '
  NR == 10 {
    print "local review_10 = \"changed\""
    print "local review_11 = \"changed\""
    print "local review_12 = \"changed\""
    print "local review_13 = \"changed\""
  }
  NR >= 10 && NR <= 16 { next }
  NR == 45 {
    print "local review_45 = \"changed\""
    print "local review_46 = \"changed\""
    print "local review_47 = \"changed\""
  }
  NR >= 45 && NR <= 47 { next }
  { print }
' main.lua > main.lua.new
mv main.lua.new main.lua

cat > preview_test.lua <<'LUA'
local failed = false
local timeout = 8000
local buf = vim.api.nvim_get_current_buf()
local gs = require("gitsigns")
local preview = require("gitsigns.actions.preview")
local ns = vim.api.nvim_create_namespace("gitsigns_preview_inline")

local function report(name, ok, detail)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function wait_for(name, predicate)
  local ok = vim.wait(timeout, predicate, 10)
  report(name, ok)
  return ok
end

local function has_preview()
  return preview.has_preview_inline(buf)
end

local function preview_marks()
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

local function preview_ids()
  local ids = {}
  for _, mark in ipairs(preview_marks()) do
    ids[#ids + 1] = mark[1]
  end
  table.sort(ids)
  return table.concat(ids, ",")
end

local function preview_stays_after_move(name, line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
  local vanished = false
  vim.wait(300, function()
    if not has_preview() then vanished = true end
    return false
  end, 5)
  report(name, not vanished and has_preview())
end

local hunks
wait_for("first review preview rendered", function()
  hunks = gs.get_hunks(buf)
  return hunks and #hunks >= 2 and has_preview()
end)

if hunks and #hunks >= 2 then
  local first = hunks[1]
  wait_for("first hunk has room for cursor movement", function()
    return first.added.count >= 4
  end)
  preview_stays_after_move("preview persists after first cursor movement", first.added.start + 1)
  preview_stays_after_move("preview persists after second cursor movement", first.added.start + 2)
  preview_stays_after_move("preview persists after third cursor movement", first.added.start + 3)

  local first_ids = preview_ids()
  local second = hunks[#hunks]
  vim.api.nvim_win_set_cursor(0, { second.added.start, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
  wait_for("moving to second hunk updates preview", function()
    return has_preview() and preview_ids() ~= first_ids
  end)

  local old_start = second.added.start
  local old_count = second.added.count
  vim.api.nvim_buf_set_lines(buf, old_start - 1, old_start + 2, false, {
    "local review_45 = \"changed again\"",
    "local review_46 = \"changed again\"",
  })

  local updated
  wait_for("gitsigns reports changed hunk contents", function()
    local current = gs.get_hunks(buf) or {}
    for _, hunk in ipairs(current) do
      if hunk.added.start == old_start and hunk.added.count ~= old_count then
        updated = hunk
        return true
      end
    end
    return false
  end)

  if updated then
    wait_for("stale preview remains observable before cursor movement", has_preview)
    local stale_ids = preview_ids()
    vim.api.nvim_win_set_cursor(0, { updated.added.start + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
    wait_for("changed hunk contents redraw the preview", function()
      return has_preview() and preview_ids() ~= stale_ids
    end)
  end
end

require("config.review_mode").stop()
wait_for("ReviewStop clears inline preview extmarks", function()
  return #preview_marks() == 0
end)

if failed then vim.cmd("cquit") end
LUA

nvim --headless "+cd $tmp" "+edit main.lua" "+ReviewStart HEAD" \
  "+luafile $tmp/preview_test.lua" "+qa!"

printf '\nok - review mode preview regression\n'
