-- Tree-sitter's Python indent drops to column 0 on a new last line after `return`; use Vim's indent instead.
return {
  "nvim-treesitter/nvim-treesitter",
  opts = { indent = { disable = { "python" } } },
}
