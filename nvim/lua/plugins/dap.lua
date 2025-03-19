local dap = require("dap")
local dapui = require("dapui")

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
    name = "Nodote xd",
    runtimeExecutable = "node",
    program = "${workspaceFolder}/dist/index.js",
    outFiles = { "${workspaceFolder}/dist/**/*.js" },
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
      { "<leader>dda", function() require("dap").continue({ before = get_args }) end, desc = "Run with Args" },
      { "<leader>dra", function() require("dap").clear_breakpoints() end, desc = "Clear Breakpoints" },
      { "<leader>dJ", function() require("dap").down() end, desc = "Down" },
      { "<leader>dK", function() require("dap").up() end, desc = "Up" },
    }
  },
}
