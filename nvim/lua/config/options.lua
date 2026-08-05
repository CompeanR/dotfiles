-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.autoindent = true
vim.opt.smartindent = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.expandtab = true

-- Disable LazyVim's automatic root directory detection
vim.g.root_spec = { "cwd" }

-- Remote / herdr: yank → Mac pasteboard via OSC 52.
-- LazyVim clears clipboard under SSH so OSC 52 "works", but without a provider
-- plain `y` never leaves nvim. Herdr panes inherit SSH_CONNECTION and set
-- HERDR_ENV=1; herdr forwards OSC 52 writes to the Mac client, but drops
-- clipboard queries — so paste stays local (use terminal Cmd+V for Mac→nvim).
if vim.env.HERDR_ENV or vim.env.SSH_CONNECTION then
  local osc52 = require("vim.ui.clipboard.osc52")
  local function paste()
    return { vim.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
  end
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = osc52.copy("+"),
      ["*"] = osc52.copy("*"),
    },
    paste = {
      ["+"] = paste,
      ["*"] = paste,
    },
  }
  vim.opt.clipboard = "unnamedplus"
end
