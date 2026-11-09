-- Vim's Python indent needs Vim syntax to tell a "#" inside a string from a comment.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function(event)
    vim.bo[event.buf].syntax = "python"
  end,
})

-- Tree-sitter's Python indent drops to column 0 on a new last line after `return`; use Vim's indent instead.
return {
  "nvim-treesitter/nvim-treesitter",
  opts = { indent = { disable = { "python" } } },
}
