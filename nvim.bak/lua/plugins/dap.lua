local dap = require("dap")

-- Backend
dap.adapters["pwa-node"] = {
  type = "server",
  host = "localhost",
  port = "${port}",
  executable = {
    command = "node",
    args = {
      vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js",
      "${port}",
    },
  },
}

dap.adapters["pwa-chrome"] = {
  type = "server",
  host = "localhost",
  port = "${port}",
  executable = {
    command = "node",
    args = {
      vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js",
      "${port}",
    },
  },
}

dap.configurations.javascript = {
  {
    type = "pwa-node",
    request = "launch",
    name = "Nodoste xd",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "npx",
    sourceMaps = true,
    protocol = "inspector",
    runtimeArgs = { "tsx", "${file}" },
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
  },
  {
    type = "pwa-node",
    request = "launch",
    name = "Debug Next.js (Turbo)",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "npm",
    sourceMaps = true,
    protocol = "inspector",
    runtimeArgs = { "run", "dev:debug" },
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
  },
  {
    type = "pwa-node",
    request = "attach",
    name = "Debug NestJS API (Turbo)",
    port = 9229,
    restart = true,
    cwd = "${workspaceFolder}/apps/api",
    sourceMaps = true,
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    outFiles = {
      "${workspaceFolder}/apps/api/dist/**/*.js",
    },
    resolveSourceMapLocations = {
      "${workspaceFolder}/apps/api/**",
      "!**/node_modules/**",
    },
    sourceMapPathOverrides = {
      ["webpack:///./*"] = "${workspaceFolder}/apps/api/*",
    },
  },
  -- {
  --   type = "pwa-node",
  --   request = "attach",
  --   name = "Attach to Node Process",
  --   processId = require("dap.utils").pick_process,
  --   cwd = "${workspaceFolder}",
  --   sourceMaps = true,
  --   skipFiles = { "<node_internals>/**", "node_modules/**" },
  --   resolveSourceMapLocations = {
  --     "${workspaceFolder}/**",
  --     "!**/node_modules/**",
  --   },
  -- },
  -- {
  --   type = "pwa-node",
  --   request = "attach",
  --   name = "Attach to Nestsote",
  --   cwd = "${workspaceFolder}",
  --   sourceMaps = true,
  --   protocol = "inspector",
  --   port = 9229,
  --   restart = true,
  --   skipFiles = { "<node_internals>/**", "node_modules/**" },
  --   resolveSourceMapLocations = {
  --     "${workspaceFolder}/**",
  --     "!**/node_modules/**",
  --   },
  -- },
  {
    type = "pwa-node",
    request = "attach",
    name = "Attach to Docker",
    cwd = "${workspaceFolder}",
    localRoot = vim.fn.getcwd(),
    remoteRoot = "/app",
    address = "localhost",
    port = 9229,
    restart = true,
    sourceMaps = true,
    protocol = "inspector",
    skipFiles = {
      "<node_internals>/**",
      "**/node_modules/**",
    },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**", -- Exclude node_modules from
    },
  },
  {
    type = "pwa-node",
    request = "launch",
    name = "🧪 Debug All Tests",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "npm",
    sourceMaps = true,
    protocol = "inspector",
    console = "integratedTerminal",
    runtimeArgs = { "test", "--", "--runInBand", "--no-coverage" },
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
    env = {
      NODE_ENV = "test",
    },
  },
  {
    type = "pwa-node",
    request = "launch",
    name = "🧪 Debug Jest Tests (Current File)",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "npm",
    sourceMaps = true,
    protocol = "inspector",
    console = "integratedTerminal",
    runtimeArgs = { "test", "--", "--runInBand", "--no-coverage", "./${relativeFile}" },
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
    env = {
      NODE_ENV = "test",
    },
  },
}
dap.configurations.typescript = dap.configurations.javascript

-- Frontend
dap.configurations.javascriptreact = {
  {
    type = "pwa-chrome",
    request = "attach",
    name = "Attach Chrome",
    port = 9222,
    -- url = "http://localhost:5173/", -- Your application URL
    webRoot = "${workspaceFolder}",
    -- userDataDir = vim.fn.expand("~/.chrome-debug-profile"),
    userDataDir = vim.fn.expand("~/.chrome-debug-profile"),
    focusWindowOnBreak = false,
  },
}
dap.configurations.typescriptreact = dap.configurations.javascriptreact

return {
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      "rcarriga/nvim-dap-ui",
      -- virtual text for the debugger
      {
        "theHamsta/nvim-dap-virtual-text",
        opts = {},
      },
    },
    keys = {
      { "<leader>da", function() require("dap").toggle_breakpoint() end, desc = "Toggle Breakpoint" },
      { "<leader>dO", function() require("dap").step_out() end, desc = "Step Out" },
      { "J", function() require("dap").step_over() end, desc = "Step Over" },
      { "<leader>dda", function() require("dap").continue() end, desc = "Run with Args" },
      { "<leader>dra", function() require("dap").clear_breakpoints() end, desc = "Clear Breakpoints" },
      {
        "<leader>dta",
        function()
          local dap = require("dap")
          local dap_breakpoints = require("dap.breakpoints")

          -- Check if we have stored breakpoints (indicating they were "disabled")
          if _G.stored_breakpoints and next(_G.stored_breakpoints) then
            -- Restore breakpoints
            for bufnr, buf_breakpoints in pairs(_G.stored_breakpoints) do
              for _, bp in pairs(buf_breakpoints) do
                dap_breakpoints.set({
                  condition = bp.condition,
                  log_message = bp.logMessage,
                  hit_condition = bp.hitCondition,
                }, bufnr, bp.line)
              end
            end

            -- Workaround: Force sync by toggling a breakpoint in a buffer that has restored breakpoints
            -- This triggers nvim-dap's internal sync mechanism for all buffers
            local current_buf = vim.api.nvim_get_current_buf()
            local current_win = vim.api.nvim_get_current_win()
            local current_pos = vim.api.nvim_win_get_cursor(current_win)

            -- Trigger sync for each buffer that has restored breakpoints
            for bufnr, buf_breakpoints in pairs(_G.stored_breakpoints) do
              if next(buf_breakpoints) then -- Buffer has breakpoints
                -- Switch to the buffer with breakpoints temporarily
                vim.api.nvim_set_current_buf(bufnr)
                vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- Go to line 1

                -- Toggle breakpoint twice to trigger sync for this buffer
                dap.toggle_breakpoint()
                dap.toggle_breakpoint()
              end
            end

            -- Restore original buffer and position
            vim.api.nvim_set_current_buf(current_buf)
            vim.api.nvim_win_set_cursor(current_win, current_pos)

            _G.stored_breakpoints = {}
            print("Breakpoints enabled")
          else
            -- Store and remove breakpoints
            local breakpoints = dap_breakpoints.get()
            _G.stored_breakpoints = {}

            for bufnr, buf_breakpoints in pairs(breakpoints) do
              _G.stored_breakpoints[bufnr] = {}
              for _, bp in pairs(buf_breakpoints) do
                table.insert(_G.stored_breakpoints[bufnr], {
                  line = bp.line,
                  condition = bp.condition,
                  logMessage = bp.logMessage,
                  hitCondition = bp.hitCondition,
                })
              end
            end

            dap.clear_breakpoints()
            print("Breakpoints disabled")
          end
        end,
        desc = "Toggle All Breakpoints",
      },
      { "<leader>dJ", function() require("dap").down() end, desc = "Down" },
      { "<leader>dK", function() require("dap").up() end, desc = "Up" },
    },
  },
}
