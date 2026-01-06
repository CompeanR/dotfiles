-- Override LazyVim's DAP UI configuration to keep UI open during server restarts
-- This file will load after the LazyVim defaults due to priority

return {
  -- Override the nvim-dap-ui plugin configuration with a higher priority
  {
    "rcarriga/nvim-dap-ui",
    -- Set a higher priority to ensure this loads after LazyVim's configuration
    priority = 100,
    -- Keep the same dependencies
    dependencies = {
      "mfussenegger/nvim-dap",
    },
    -- Override the config function
    config = function()
      local dap = require("dap")
      local dapui = require("dapui")

      -- Configure the UI (use your preferred layout)
      dapui.setup({
        layouts = {
          {
            elements = {
              "scopes",
              "breakpoints",
              "stacks",
              "watches",
            },
            size = 40,
            position = "left",
          },
          {
            elements = {
              "repl",
              "console",
            },
            size = 10,
            position = "bottom",
          },
        },
      })

      -- Clear existing listeners that might close the UI
      dap.listeners.before = dap.listeners.before or {}
      dap.listeners.before.event_terminated = {}
      dap.listeners.before.event_exited = {}

      -- Keep only the listener to open the UI when session initializes
      dap.listeners.after = dap.listeners.after or {}
      dap.listeners.after.event_initialized = dap.listeners.after.event_initialized or {}
      dap.listeners.after.event_initialized["dapui_config"] = function()
        dapui.open()
      end

      -- Create commands for manual control
      vim.api.nvim_create_user_command("DapUIOpen", function()
        dapui.open()
      end, {})

      vim.api.nvim_create_user_command("DapUIClose", function()
        dapui.close()
      end, {})

      vim.api.nvim_create_user_command("DapUIToggle", function()
        dapui.toggle()
      end, {})

      -- Add keymaps for manual control
      vim.keymap.set("n", "<leader>du", function()
        dapui.toggle()
      end, { desc = "Toggle DAP UI" })

      -- Override the default <leader>de to automatically eval expression under cursor
      vim.keymap.set("n", "<leader>de", function()
        -- Get the expression under cursor
        local expr = vim.fn.expand("<cexpr>")
        if expr and expr ~= "" then
          -- Directly eval the expression under cursor
          dapui.eval(expr, { enter = true })
        else
          -- Fallback to interactive eval if no expression found
          dapui.eval(nil, { enter = true })
        end
      end, { desc = "DAP Eval Expression" })

      -- Show a notification to confirm the override
      vim.notify("DAP UI handlers configured to keep UI open during debugging", vim.log.levels.INFO)
    end,
  },
}
