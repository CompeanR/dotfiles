return {
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = {
        -- Formatters
        "prettier",
        "stylua",
        -- Linters
        "eslint_d",
      },
    },
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    opts = {
      ensure_installed = {
        "js-debug-adapter", -- For pwa-node and pwa-chrome
      },
      automatic_installation = true,
    },
  },
}
