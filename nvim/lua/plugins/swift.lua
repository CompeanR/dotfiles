return {
  -- Swift LSP
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        sourcekit = {
          cmd = { "xcrun", "sourcekit-lsp" },
          single_file_support = true,
          root_dir = function(bufnr, on_dir)
            local fname = vim.api.nvim_buf_get_name(bufnr)
            local util = require("lspconfig.util")
            on_dir(util.root_pattern("Package.swift", ".git")(fname)
              or util.root_pattern("*.xcodeproj", "*.xcworkspace")(fname)
              or vim.fs.dirname(fname)) -- fallback for standalone swift files
          end,
        },
      },
    },
  },
  -- Treesitter parser for Swift
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "swift" })
    end,
  },
  -- Formatter integration (LazyVim uses conform.nvim)
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        swift = { "swift_format" }, -- use Apple swift-format
        -- or: swift = { "swiftformat" }, -- if you prefer Nick Lockwood's SwiftFormat
      },
    },
  },
}
