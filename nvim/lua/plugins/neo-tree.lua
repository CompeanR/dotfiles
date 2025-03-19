local dynamic_width = math.floor(vim.o.columns * 0.24)

return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    window = {
      -- auto_expand_width = true,
      width = dynamic_width,
    },
  },
}
