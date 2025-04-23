local dap = require("dap")

dap.adapters["pwa-node"] = {
  type = "server",
  host = "localhost",
  port = 9229,
  executable = {
    command = "node",
    args = {
      vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js",
      "9229",
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
    runtimeArgs = { "nodemon", "--exec", "ts-node", "${file}"},
    skipFiles = {"<node_internals>/**", "node_modules/**"},
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**"
    },
  },
  {
    type = "pwa-node",
    request = "attach",
    name = "Attach to Node Process",
    processId = require("dap.utils").pick_process,
    cwd = "${workspaceFolder}",
    sourceMaps = true,
    skipFiles = {"<node_internals>/**", "node_modules/**"},
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**"
    },
  },
  {
    type = "pwa-node",
    request = "launch",
    name = "Launch Node.js File",
    program = "${workspaceFolder}/bin/www",
    cwd = "${workspaceFolder}",
    runtimeExecutable = "node",
    sourceMaps = true,
    protocol = "inspector",
    skipFiles = {"<node_internals>/**", "node_modules/**"},
    resolveSourceMapLocations = {
      "${workspaceFolder}/**",
      "!**/node_modules/**"
    },
  },
}

dap.configurations.typescript = dap.configurations.javascript

dap.configurations.javascriptreact = {
  {
    name = "Attach to chrome",
    type = "chrome",
    request = "attach",
    program = "${file}",
    cwd = vim.fn.getcwd(),
    sourceMaps = true,
    protocol = "inspector",
    port = 9222,
    webRoot = "${workspaceFolder}",
  },
}

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
      { "<leader>dJ", function() require("dap").down() end, desc = "Down" },
      { "<leader>dK", function() require("dap").up() end, desc = "Up" },
    }
  },
}
