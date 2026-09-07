-- Runnable with: nvim --headless -u NORC -c "luafile tests/nvim_lsp_peek_test.lua" -c qa
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/") or "."
package.path = root .. "/nvim/lua/?.lua;" .. package.path

local peek = require("config.lsp_peek")

local failed = false
local function report(name, ok, detail)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name .. (detail and (": " .. detail) or ""))
  end
end

local long = string.rep("x", 70)
local lines = {}
for i = 1, 20 do
  lines[i] = string.format("  function body_line_%02d() { return '%s'; }", i, long)
end
local sample = lines[1]
local want_w = math.min(vim.fn.strdisplaywidth(sample), math.floor(80 * 0.9))
local w, h = peek.float_size(lines, 80, 24)
report("width matches display width capped at 90%", w == want_w, "got " .. w .. " want " .. want_w)
report("height is 60% of window not leftover cursor rows", h == math.floor(24 * 0.6), "got " .. h)

local uri, range = peek.location_range({
  targetUri = "file:///tmp/x.ts",
  targetRange = { start = { line = 0, character = 0 }, ["end"] = { line = 99, character = 0 } },
  targetSelectionRange = { start = { line = 12, character = 4 }, ["end"] = { line = 12, character = 10 } },
})
report("prefers selection range over whole-file targetRange", range.start.line == 12, "got " .. tostring(range and range.start.line))
report("keeps uri", uri == "file:///tmp/x.ts", "got " .. tostring(uri))

vim.o.lines = 24
vim.o.columns = 80
vim.o.scrolloff = 8
pcall(vim.api.nvim_win_set_height, 0, 24)
pcall(vim.api.nvim_win_set_width, 0, 80)

local path = vim.fn.tempname() .. ".ts"
vim.fn.writefile(lines, path)
vim.cmd.edit(vim.fn.fnameescape(path))
vim.api.nvim_win_set_cursor(0, { 20, 0 })

local method_line = 10 -- 0-indexed; leave unrelated lines above so a mid-file peek can fail
local loc = {
  uri = vim.uri_from_bufnr(0),
  range = { start = { line = method_line, character = 2 }, ["end"] = { line = method_line, character = 10 } },
}
peek.open(loc, "textDocument/implementation")

local peek_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.w[win].lsp_peek_method == "textDocument/implementation" then
    peek_win = win
    break
  end
end
report("opens a peek window", peek_win ~= nil)
if peek_win then
  local cfg = vim.api.nvim_win_get_config(peek_win)
  report("float is at least 60 columns wide", cfg.width >= 60, "got " .. tostring(cfg.width))
  report("float is at least 8 rows tall", cfg.height >= 8, "got " .. tostring(cfg.height))
  local topline = vim.fn.getwininfo(peek_win)[1].topline
  report("peek starts at the method", topline == method_line + 1, "got " .. tostring(topline) .. " want " .. (method_line + 1))

  local mapped = vim.fn.maparg("q", "n", false, true)
  report("q closes peek without focusing it", type(mapped) == "table" and mapped.desc == "lsp-peek-close", vim.inspect(mapped))
  vim.api.nvim_feedkeys("q", "xt", false)
  report("q closes the peek", not vim.api.nvim_win_is_valid(peek_win))
  report("q is unmapped after close", vim.fn.maparg("q", "n") == "")
end

if failed then
  vim.cmd("cquit")
end
print("all passed")
vim.cmd("qa!")
