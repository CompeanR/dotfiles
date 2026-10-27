return {
  {
    "sainnhe/gruvbox-material",
    lazy = false,
    priority = 1000,
    init = function()
      require("config.theme").setup()
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = function()
        require("config.theme").load()
      end,
    },
  },
}
