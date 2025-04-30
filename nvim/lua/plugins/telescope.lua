-- In lua/plugins/telescope.lua
return {
  "nvim-telescope/telescope.nvim",
  keys = {
    -- Custom keybinding to show hidden files including .env
    {
      "<leader>fh",
      "<cmd>Telescope find_files hidden=true no_ignore=true<cr>",
      desc = "Find hidden files (including .env)",
    },
  },
}
