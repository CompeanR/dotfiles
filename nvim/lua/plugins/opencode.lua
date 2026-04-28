return {
  "NickvanDyke/opencode.nvim",
  dependencies = {
    -- Recommended for `ask()` and `select()`.
    -- Required for `snacks` provider.
    ---@module 'snacks' <- Loads `snacks.nvim` types for configuration intellisense.
    { "folke/snacks.nvim", opts = { input = {}, picker = {}, terminal = {} } },
  },
  config = function()
    ---@type opencode.Opts
    vim.g.opencode_opts = {
      -- Your configuration, if any — see `lua/opencode/config.lua`, or "goto definition".
    }

    -- Required for `opts.auto_reload`.
    vim.o.autoread = true

    -- Recommended/example keymaps.
    vim.keymap.set({ "n", "x" }, "<leader>oa", function() require("opencode").ask("@this: ", { submit = true }) end, { desc = "Ask opencode" })
    vim.keymap.set({ "n", "x" }, "<C-x>", function() require("opencode").select() end, { desc = "Execute opencode action…" })
    vim.keymap.set({ "n", "x" }, "ga", function() require("opencode").prompt("@this") end, { desc = "Add to opencode" })
    vim.keymap.set({ "n", "x" }, "<leader>oe", function() require("opencode").prompt("@this: Explain this code clearly and concisely.", { submit = true }) end, { desc = "Explain selected text" })
    vim.keymap.set({ "n", "t" }, "<leader>oo", function() require("opencode").toggle() end, { desc = "Toggle opencode" })
    vim.keymap.set("n", "<S-C-u>", function() require("opencode").command("session.half.page.up") end, { desc = "opencode half page up" })
    vim.keymap.set("n", "<S-C-d>", function() require("opencode").command("session.half.page.down") end, { desc = "opencode half page down" })
    -- You may want these if you stick with the opinionated "<C-a>" and "<C-x>" above — otherwise consider "<leader>o".
    vim.keymap.set("n", "+", "<C-a>", { desc = "Increment", noremap = true })
    vim.keymap.set("n", "<leader>o-", "<C-x>", { desc = "Decrement", noremap = true })

    -- Fix: Override tmux-navigator terminal mappings inside the opencode terminal buffer.
    -- Without this, <C-h/j/k/l> fire TmuxNavigate* instead of being sent to the TUI,
    -- and <Esc> requires <C-\><C-n> to exit terminal insert mode.
    vim.api.nvim_create_autocmd("TermOpen", {
      pattern = "term://*opencode*",
      callback = function(ev)
        local buf = ev.buf
        local topts = { buffer = buf, silent = true }

        -- Pass <C-h/j/k/l> through to the terminal (overrides vim-tmux-navigator)
        vim.keymap.set("t", "<C-h>", "<C-h>", topts)
        vim.keymap.set("t", "<C-j>", "<C-j>", topts)
        vim.keymap.set("t", "<C-k>", "<C-k>", topts)
        vim.keymap.set("t", "<C-l>", "<C-l>", topts)

        -- Allow jk to exit terminal insert mode
        vim.keymap.set("t", "jk", "<C-\\><C-n>", topts)
      end,
    })
  end,
}
