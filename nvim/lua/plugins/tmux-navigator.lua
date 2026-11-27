-- Inside herdr-app (HC_TERMINAL_SOCKET): splits first, then `herdr-app do pane.go` at the edge.
-- Inside herdr TUI: vim-herdr-navigation owns <C-h/j/k/l>.
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
    local function setup_herdr_app()
      local function nav(wincmd, dir)
        local prev = vim.api.nvim_get_current_win()
        vim.cmd("wincmd " .. wincmd)
        if vim.api.nvim_get_current_win() == prev then
          vim.system({ "herdr-app", "do", "pane.go", vim.json.encode({ direction = dir }) })
        end
      end
      for lhs, spec in pairs({ ["<C-h>"] = { "h", "left" }, ["<C-j>"] = { "j", "down" }, ["<C-k>"] = { "k", "up" }, ["<C-l>"] = { "l", "right" } }) do
        vim.keymap.set("n", lhs, function()
          nav(spec[1], spec[2])
        end, { silent = true, desc = "Navigate " .. spec[2] .. " (vim/herdr-app)" })
      end
    end

    local function setup()
      if vim.env.HC_TERMINAL_SOCKET and not vim.env.HERDR_PANE_ID then
        setup_herdr_app()
        return
      end
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
