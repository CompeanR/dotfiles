return {
  {
    dir = "~/Development/pr-manager/nvim",
    name = "prm",
    lazy = false,
    opts = {
      on_review = function(dir, pr)
        vim.cmd.tcd(vim.fn.fnameescape(dir))
        require("config.review_mode").start(tostring(pr.number), { base = pr.base })
      end,
    },
    config = function(_, opts)
      require("prm").setup(opts)
      vim.api.nvim_create_autocmd("User", {
        pattern = "PrmChanged",
        callback = function()
          local ok, lualine = pcall(require, "lualine")
          if ok then lualine.refresh() end
        end,
      })
    end,
  },
}
