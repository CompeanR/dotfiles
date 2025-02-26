-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local keymap = vim.keymap -- for conciseness

-- General Keymaps -------------------

-- use jk to exit insert mode
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })

-- Select All
keymap.set("n", "<c-a>", "gg<S-v>G", { desc = "Select All" })

-- Debugger Keymaps
keymap.del("n", "<leader>db")
keymap.del("n", "<leader>do")
keymap.del("n", "<leader>dk")
keymap.set("x", "J", ":m '>+1<CR>gv=gv", { noremap = true, silent = true })
keymap.set("x", "K", ":m '<-2<CR>gv=gv", { noremap = true, silent = true })

--- Mimics the "Next occurrence" behavior from other IDES.
keymap.set("n", "<C-n>", function()
  vim.cmd("let @/ = '\\<' .. expand('<cword>') .. '\\>'") -- Set search to the word under cursor
  vim.api.nvim_feedkeys("cgn", "n", false) -- Change next occurrence
end, { noremap = true, silent = true })

--- Expands an empty tag into its full form.
---
--- This function identifies an empty HTML/XML tag
--- and after pressing <CR> it adds a line and the corresponding identation.
---
--- @return nil
local function expand_empty_tag()
  local line = vim.api.nvim_get_current_line()
  local tag = line:match("^%s*<([^%s/>]+).-</%1>%s*$")
  if tag then
    vim.schedule(function()
      local indent = line:match("^(%s*)") or ""
      local shiftwidth = vim.bo.shiftwidth
      local new_indent = indent .. string.rep(" ", shiftwidth)
      local new_lines = {
        indent .. "<" .. tag .. ">",
        new_indent,
        indent .. "</" .. tag .. ">",
      }
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      vim.api.nvim_buf_set_lines(0, row, row + 1, false, new_lines)
      vim.api.nvim_win_set_cursor(0, { row + 2, #new_indent })
    end)
    return ""
  end
  return "<CR>"
end
vim.keymap.set("i", "<CR>", expand_empty_tag, { expr = true, noremap = true, desc = "Expand empty HTML/JSX tags" })
