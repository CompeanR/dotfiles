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

    -- True if the opencode terminal panel is currently visible in a window.
    local function opencode_visible()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match("^term://.*opencode") then
          return true
        end
      end
      return false
    end

    -- Ask opencode. Opens the panel first if it's closed/hidden so the reply
    -- is visible — toggling it hidden leaves the server running, so without
    -- this the prompt would be sent but never shown. Context is captured
    -- before the window change so a visual selection / cursor isn't lost.
    vim.keymap.set({ "n", "x" }, "<leader>oa", function()
      local context = require("opencode.context").new()
      if not opencode_visible() then
        require("opencode").toggle()
      end
      require("opencode").ask("@this: ", { submit = true, context = context })
    end, { desc = "Ask opencode" })
    vim.keymap.set({ "n", "x" }, "<C-x>", function() require("opencode").select() end, { desc = "Execute opencode action…" })
    vim.keymap.set({ "n", "x" }, "ga", function() require("opencode").prompt("@this") end, { desc = "Add to opencode" })
    vim.keymap.set(
      { "n", "x" },
      "<leader>oe",
      function() require("opencode").prompt("@this: Explain this code clearly and concisely.", { submit = true }) end,
      { desc = "Explain selected text" }
    )
    vim.keymap.set("n", "<leader>oo", function() require("opencode").toggle() end, { desc = "Toggle opencode" })
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

        -- Let <C-h> leave the opencode terminal and move to the left window.
        vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-w>h", topts)

        -- Pass the remaining tmux navigation keys through to the terminal.
        vim.keymap.set("t", "<C-j>", "<C-j>", topts)
        vim.keymap.set("t", "<C-k>", "<C-k>", topts)
        vim.keymap.set("t", "<C-l>", "<C-l>", topts)
      end,
    })

    -- Mirror of the <C-h> mapping above: when navigating into the opencode
    -- terminal (e.g. <C-l> from a nvim window), drop straight into terminal
    -- insert mode so you can type immediately — no manual `i` needed.
    --
    -- Deferred via vim.schedule + a focus check: toggle()/open() briefly
    -- focus the opencode window then switch back, and `startinsert` only
    -- takes effect once control returns to the main loop — so a bare call
    -- here would land insert mode in whatever window is focused *then*
    -- (your code window), not opencode. The check skips that case and only
    -- fires insert mode when opencode actually stays focused.
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = "term://*opencode*",
      callback = function(ev)
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == ev.buf then
            vim.cmd("startinsert")
          end
        end)
      end,
    })
  end,
}
