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

dap.configurations.javascript = {
  {
    type = "pwa-node",
    request = "launch",
    name = "Nodoste xd",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "npx",
    sourceMaps = true,
    protocol = "inspector",
    runtimeArgs = { "nodemon", "--exec", "ts-node", "${file}" },
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
  },
  {
    type = "pwa-node",
    request = "launch",
    name = "Nestsote",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "npm",
    sourceMaps = true,
    protocol = "inspector",
    console = "internal",
    runtimeArgs = { "run", "start:dev" },
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
  },
  {
    type = "pwa-node",
    request = "attach",
    name = "Attach to Node Process",
    processId = require("dap.utils").pick_process,
    cwd = "${workspaceFolder}",
    sourceMaps = true,
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
    },
  },
  {
    type = "pwa-node",
    request = "attach",
    name = "Attach to Nestsote",
    cwd = "${workspaceFolder}",
    sourceMaps = true,
    protocol = "inspector",
    port = 9229,
    restart = true,
    skipFiles = { "<node_internals>/**", "node_modules/**" },
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**",
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
    runtimeArgs = { "test", "--", "--runInBand", "--no-coverage", "${relativeFile}" },
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
    name = "Attach to chrome",
    type = "chrome-debug-adapter",
    request = "attach",
    program = "${file}",
    cwd = vim.fn.getcwd(),
    sourceMaps = true,
    protocol = "inspector",
    port = 9222,
    webRoot = "${workspaceFolder}",
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
      {
        "<leader>da",
        function()
          require("dap").toggle_breakpoint()
        end,
        desc = "Toggle Breakpoint",
      },
      {
        "<leader>dO",
        function()
          require("dap").step_out()
        end,
        desc = "Step Out",
      },
      {
        "J",
        function()
          require("dap").step_over()
        end,
        desc = "Step Over",
      },
      {
        "<leader>dda",
        function()
          require("dap").continue()
        end,
        desc = "Run with Args",
      },
      {
        "<leader>dra",
        function()
          require("dap").clear_breakpoints()
        end,
        desc = "Clear Breakpoints",
      },
      {
        "<leader>dJ",
        function()
          require("dap").down()
        end,
        desc = "Down",
      },
      {
        "<leader>dK",
        function()
          require("dap").up()
        end,
        desc = "Up",
      },
    },
  },
}
