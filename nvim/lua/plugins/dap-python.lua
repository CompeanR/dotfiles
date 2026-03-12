return {
  "mfussenegger/nvim-dap-python",
  config = function()
    local dap = require("dap")

    -- Path to debugpy (Mason installs it here)
    local debugpy_path = "~/.local/share/nvim/mason/packages/debugpy/venv/bin/python"
    require("dap-python").setup(debugpy_path)

    -- FastAPI configuration
    table.insert(dap.configurations.python, {
      type = "python",
      request = "launch",
      name = "FastAPI",
      module = "uvicorn",
      args = {
        "main:app", -- Change to your app path (e.g., "src.main:app")
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
        "--reload", -- Remove if you don't want reload
      },
      jinja = true,
      console = "integratedTerminal",
    })

    table.insert(dap.configurations.python, {
      type = "python",
      request = "attach",
      name = "FastAPI (Attach)",
      connect = {
        host = "127.0.0.1",
        port = 5678,
      },
      pathMappings = {
        {
          localRoot = "${workspaceFolder}",
          remoteRoot = "${workspaceFolder}",
        },
      },
    })
  end,
}
