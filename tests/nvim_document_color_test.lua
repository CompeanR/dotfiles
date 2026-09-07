-- Runnable with: nvim --headless -u NORC -c "luafile tests/nvim_document_color_test.lua" -c qa
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/") or "."
dofile(root .. "/nvim/lua/config/options.lua")

local failed = false
local function report(name, ok, detail)
  if ok then
    print("ok - " .. name)
  else
    failed = true
    print("not ok - " .. name .. (detail and (": " .. detail) or ""))
  end
end

report("document colors start disabled", not vim.lsp.document_color.is_enabled())
report("DocumentColorToggle exists", vim.fn.exists(":DocumentColorToggle") == 2)

vim.cmd("DocumentColorToggle")
report("toggle enables", vim.lsp.document_color.is_enabled())
vim.cmd("DocumentColorToggle")
report("toggle disables", not vim.lsp.document_color.is_enabled())

if failed then
  vim.cmd("cquit")
end
print("all passed")
