return {
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = {
        "eslint_d",
        "js-debug-adapter", -- For pwa-node and pwa-chrome
      },
    },
  },
}
