return {
  {
    "nvim-treesitter/nvim-treesitter",
    config = function(_, opts)
      require("nvim-treesitter.configs").setup(opts)

      -- Register HTTP filetype
      vim.filetype.add({
        extension = {
          http = "http",
          rest = "http",
        },
      })
    end,
  },
}
