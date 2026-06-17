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

    local function opencode_cmd()
      local opencode_nvim_config = vim.fn.stdpath("config") .. "/opencode-nvim"
      return "env OPENCODE_CONFIG_DIR="
        .. vim.fn.shellescape(opencode_nvim_config)
        .. " OPENCODE_TUI_CONFIG="
        .. vim.fn.shellescape(opencode_nvim_config .. "/tui.json")
        .. " opencode --port"
    end

    local function opencode_should_open_horizontal()
      return vim.o.columns < 140
    end

    local function opencode_win_opts()
      if opencode_should_open_horizontal() then
        return {
          split = "below",
          height = math.floor(vim.o.lines * 0.5),
        }
      end

      return {
        split = "right",
        width = math.floor(vim.o.columns * 0.5),
      }
    end

    local function opencode_win()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match("^term://.*opencode") then
          return win
        end
      end
    end

    local function resize_opencode()
      local win = opencode_win()
      if not win then
        return
      end

      local previous_win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(win)
      if opencode_should_open_horizontal() then
        vim.cmd("wincmd J")
        vim.cmd("resize " .. math.floor(vim.o.lines * 0.5))
      else
        vim.cmd("wincmd L")
        vim.cmd("vertical resize " .. math.floor(vim.o.columns * 0.5))
      end
      if vim.api.nvim_win_is_valid(previous_win) then
        vim.api.nvim_set_current_win(previous_win)
      end
    end

    ---@type opencode.Opts
    local opencode_server_opts = {
      start = function()
        require("opencode.terminal").open(opencode_cmd(), opencode_win_opts())
      end,
      stop = function()
        require("opencode.terminal").close()
      end,
      toggle = function()
        require("opencode.terminal").toggle(opencode_cmd(), opencode_win_opts())
      end,
    }

    vim.g.opencode_opts.server = opencode_server_opts

    local ok, opencode_config = pcall(require, "opencode.config")
    if ok then
      opencode_config.opts.server = opencode_server_opts
    end

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
    vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        vim.schedule(resize_opencode)
      end,
    })

    vim.api.nvim_create_autocmd("TermOpen", {
      pattern = "term://*opencode*",
      callback = function(ev)
        local buf = ev.buf
        local topts = { buffer = buf, silent = true }

        -- Let tmux-style nav leave the opencode terminal in the matching direction.
        -- <C-j> keeps window-nav when a lower split exists; otherwise it is
        -- passed through to opencode so the TUI can insert a newline.
        -- <C-l> still passes through: from a left nvim window it enters opencode,
        -- and BufEnter below starts terminal insert mode automatically.
        vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-w>h", topts)
        vim.keymap.set("t", "<C-j>", function()
          if vim.fn.winnr("j") == vim.fn.winnr() then
            vim.api.nvim_chan_send(vim.b.terminal_job_id, "\n")
            return
          end

          vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n><C-w>j"), "n", false)
        end, topts)
        vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-w>k", topts)
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
