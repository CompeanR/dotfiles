-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local keymap = vim.keymap -- for conciseness

---------------------
-- General Keymaps -------------------

-- use jk to exit insert mode
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })

-- clear search highlights
-- keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search highlights" })

-- Select All
keymap.set("n", "<D-a>", "gg<S-v>G", { desc = "Select All" })

-- General navigation
keymap.set("n", "<D-d>", "<C-d>", { desc = "Scroll down (Mac)" })
keymap.set("n", "<D-u>", "<C-u>", { desc = "Scroll up (Mac)" })
keymap.set("n", "<D-o>", "<C-o>", { desc = "Jump to older cursor position (Mac)" })
keymap.set("n", "<D-i>", "<C-i>", { desc = "Jump to newer cursor position (Mac)" })
keymap.set("n", "<D-r>", "<C-r>", { desc = "Redo (Mac)" })
