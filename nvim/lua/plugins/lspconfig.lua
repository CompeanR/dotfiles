return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },

      servers = {
        tailwindcss = {
          filetypes = {
            "templ",
            "vue",
            "html",
            "astro",
            "javascript",
            "typescript",
            "typescriptreact",
            "javascriptreact",
            "react",
            "htmlangular",
          },
        },
        intelephense = {
          filetypes = { "php", "blade" },
        },
      },
    },
  },
}
