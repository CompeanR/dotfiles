return {
  "NickvanDyke/opencode.nvim",
  dependencies = {
    -- Recommended for `ask()` and `select()`.
    -- Required for `snacks` provider / terminal start.
    ---@module 'snacks'
    { "folke/snacks.nvim", opts = { input = {}, picker = {}, terminal = {} } },
  },
  config = function()
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

    ---@return snacks.terminal.Opts
    local function snacks_terminal_opts()
      if opencode_should_open_horizontal() then
        return {
          win = {
            position = "bottom",
            height = 0.5,
            enter = false,
          },
        }
      end
      return {
        win = {
          position = "right",
          width = 0.45,
          enter = false,
        },
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
        vim.cmd("vertical resize " .. math.floor(vim.o.columns * 0.45))
      end
      if vim.api.nvim_win_is_valid(previous_win) then
        vim.api.nvim_set_current_win(previous_win)
      end
    end

    local function toggle_opencode()
      require("snacks.terminal").toggle(opencode_cmd(), snacks_terminal_opts())
    end

    local function ensure_opencode_visible()
      local term = require("snacks.terminal").get(opencode_cmd(), { create = false })
      if term then
        term:show()
        return
      end
      require("snacks.terminal").open(opencode_cmd(), snacks_terminal_opts())
    end

    ---@type opencode.Opts
    vim.g.opencode_opts = {
      server = {
        -- v0.11+ dropped opencode.terminal / server.toggle|stop — snacks owns the TUI.
        start = function()
          require("snacks.terminal").open(opencode_cmd(), snacks_terminal_opts())
        end,
      },
    }

    vim.o.autoread = true

    vim.keymap.set({ "n", "x" }, "<leader>oa", function()
      ensure_opencode_visible()
      require("opencode").ask("@this: ")
    end, { desc = "Ask opencode" })
    vim.keymap.set({ "n", "x" }, "<C-x>", function()
      require("opencode").select()
    end, { desc = "Execute opencode action…" })
    vim.keymap.set({ "n", "x" }, "ga", function()
      require("opencode").prompt("@this")
    end, { desc = "Add to opencode" })
    vim.keymap.set({ "n", "x" }, "<leader>oe", function()
      require("opencode").prompt("@this: Explain this code clearly and concisely.")
    end, { desc = "Explain selected text" })
    vim.keymap.set("n", "<leader>oo", toggle_opencode, { desc = "Toggle opencode" })
    vim.keymap.set("n", "<S-C-u>", function()
      require("opencode").command("session.half.page.up")
    end, { desc = "opencode half page up" })
    vim.keymap.set("n", "<S-C-d>", function()
      require("opencode").command("session.half.page.down")
    end, { desc = "opencode half page down" })
    vim.keymap.set("n", "+", "<C-a>", { desc = "Increment", noremap = true })
    vim.keymap.set("n", "<leader>o-", "<C-x>", { desc = "Decrement", noremap = true })

    vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        vim.schedule(resize_opencode)
      end,
    })

    -- Window-nav leaves the opencode TUI; <C-l> stays in-TUI (clear / enter from left).
    vim.api.nvim_create_autocmd("TermOpen", {
      pattern = "term://*opencode*",
      callback = function(ev)
        local buf = ev.buf
        local topts = { buffer = buf, silent = true }

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

    -- Entering the opencode term (e.g. <C-l> from a code split) starts insert.
    -- Deferred + focus check: open/toggle briefly focuses then returns.
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
