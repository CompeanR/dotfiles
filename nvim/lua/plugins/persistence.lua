local function close_neotree_after_load()
  vim.defer_fn(function()
    vim.cmd("Neotree close")
  end, 50)
end

return {
  "folke/persistence.nvim",
  keys = {
    {
      "<leader>qs",
      function()
        require("persistence").load()
        close_neotree_after_load()
      end,
      desc = "Restore Session",
    },
    {
      "<leader>qS",
      function()
        require("persistence").select()
        vim.defer_fn(function()
          vim.cmd("Neotree close")
        end, 150)
      end,
      desc = "Select Session",
    },
    {
      "<leader>ql",
      function()
        require("persistence").load({ last = true })
        close_neotree_after_load()
      end,
      desc = "Restore Last Session",
    },
  },
}
