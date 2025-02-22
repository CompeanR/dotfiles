-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local keymap = vim.keymap -- for conciseness

-- General Keymaps -------------------

-- use jk to exit insert mode
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })

-- Select All
keymap.set("n", "<c-a>", "gg<S-v>G", { desc = "Select All" })

keymap.del("n", "<leader>db")
keymap.del("n", "<leader>do")
keymap.del("n", "<leader>dk")
keymap.set("x", "J", ":m '>+1<CR>gv=gv", { noremap = true, silent = true })
keymap.set("x", "K", ":m '<-2<CR>gv=gv", { noremap = true, silent = true })
