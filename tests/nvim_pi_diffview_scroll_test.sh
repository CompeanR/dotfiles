#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "$tmp/scroll_test.lua" <<'LUA'
local root = assert(os.getenv("DOTFILES_ROOT"))
package.path = root .. "/nvim/lua/?.lua;" .. package.path

local fake_terminal = { last = nil }
function fake_terminal.list() return {} end
function fake_terminal.open(_, opts)
  vim.cmd("rightbelow vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].filetype = "snacks_terminal"

  local term = { buf = buf, win = win, opts = opts }
  fake_terminal.last = term
  if opts.win.on_buf then opts.win.on_buf(term) end
  vim.fn.termopen({ "sh", "-c", "for i in $(seq 1 1000); do printf 'output-%04d\\n' \"$i\"; sleep 0.01; done" })
  if opts.win.on_win then opts.win.on_win(term) end
  return term
end

package.loaded["snacks.terminal"] = fake_terminal
dofile(root .. "/nvim/lua/plugins/pi-diffview.lua")
local pi = assert(package.loaded.pi_diffview)

vim.cmd("enew")
local editor_win = vim.api.nvim_get_current_win()
pi.toggle()
local term = assert(fake_terminal.last)
vim.api.nvim_set_current_win(editor_win)

local function view()
  return vim.api.nvim_win_call(term.win, function()
    return {
      top = vim.fn.line("w0"),
      bottom = vim.fn.line("w$"),
      cursor = vim.api.nvim_win_get_cursor(0)[1],
    }
  end)
end

local output_ready = vim.wait(5000, function()
  return vim.api.nvim_buf_line_count(term.buf) >= 100
end, 10)
vim.wait(200, function() return false end, 10)

local editor_view = view()
local lines = vim.api.nvim_buf_line_count(term.buf)
local follows_output = output_ready and editor_view.bottom == lines and editor_view.cursor == lines

vim.api.nvim_set_current_win(term.win)
vim.cmd("stopinsert")
vim.cmd("normal! \21")
local after_up = view()
vim.wait(250, function() return false end, 10)
local after_up_wait = view()
vim.cmd("normal! \4")
local after_down = view()
vim.wait(250, function() return false end, 10)
local after_down_wait = view()
local manual_scroll_works =
  after_up.top < editor_view.top
  and after_up_wait.top <= after_up.top + 1
  and after_down.top > after_up_wait.top
  and after_down_wait.top >= after_down.top - 1

vim.api.nvim_set_current_win(editor_win)
vim.wait(100, function() return false end, 10)
local final_view = view()
local follows_again = final_view.bottom == vim.api.nvim_buf_line_count(term.buf)

if follows_output and manual_scroll_works and follows_again then
  print("ok - pi terminal follows output without overriding manual scroll")
else
  print(string.format(
    "not ok - pi terminal scroll contract: follows=%s manual=%s resumes=%s editor=%s up=%s up_wait=%s down=%s down_wait=%s final=%s",
    tostring(follows_output),
    tostring(manual_scroll_works),
    tostring(follows_again),
    vim.inspect(editor_view),
    vim.inspect(after_up),
    vim.inspect(after_up_wait),
    vim.inspect(after_down),
    vim.inspect(after_down_wait),
    vim.inspect(final_view)
  ))
  vim.cmd("cquit")
end
LUA

DOTFILES_ROOT="$root" nvim --clean --headless -u NONE -l "$tmp/scroll_test.lua"
