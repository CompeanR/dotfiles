local dap = require("dap")
local dapui = require("dapui")

dap.adapters.chrome = {
  type = "executable",
  command = "node",
  args = { os.getenv("HOME") .. "/path/to/vscode-chrome-debug/out/src/chromeDebug.js" }, -- TODO adjust
}

dap.configurations.javascriptreact = { -- change this to javascript if needed
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

return   {
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
    },
  },
}

