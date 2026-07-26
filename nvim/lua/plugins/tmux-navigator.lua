-- Inside herdr: vim-herdr-navigation owns <C-h/j/k/l>.
-- Outside herdr: falls back to vim-tmux-navigator (or plain wincmd).
--
-- LazyVim remaps <C-hjkl> → <C-w>* on VeryLazy (after plugin config).
-- Re-apply after LazyVimKeymaps so herdr/tmux nav wins.
return {
  "christoomey/vim-tmux-navigator",
  lazy = false,
  init = function()
    vim.g.tmux_navigator_no_mappings = 1
  end,
  config = function()
    local function setup()
      local matches = vim.fn.glob(
        vim.fn.expand("~/.config/herdr/plugins/github/vim-herdr-navigation-*/editor/nvim.lua"),
        true,
        true
      )
      if matches[1] then
        -- ponytail: herdr hashes the install dir; glob beats a brittle path
        dofile(matches[1])
        return
      end

      local map = function(lhs, cmd, desc)
        vim.keymap.set("n", lhs, cmd, { silent = true, desc = desc })
      end
      map("<C-h>", "<cmd>TmuxNavigateLeft<cr>", "Navigate Left")
      map("<C-j>", "<cmd>TmuxNavigateDown<cr>", "Navigate Down")
      map("<C-k>", "<cmd>TmuxNavigateUp<cr>", "Navigate Up")
      map("<C-l>", "<cmd>TmuxNavigateRight<cr>", "Navigate Right")
      map("<C-\\>", "<cmd>TmuxNavigatePrevious<cr>", "Navigate Previous")
    end

    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyVimKeymaps",
      once = true,
      callback = setup,
    })
  end,
}
