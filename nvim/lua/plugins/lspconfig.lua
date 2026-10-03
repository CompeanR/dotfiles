---@param provider string fzf-lua provider name
---@return function
local function picker(provider)
  return function() require("fzf-lua")[provider]({ jump1 = true, ignore_current_line = true }) end
end

local peek = require("config.lsp_peek")

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },

      servers = {
        ["*"] = {
          keys = {
            { "gd", picker("lsp_definitions"), desc = "Goto Definition", has = "definition" },
            { "gp", peek.peek_definition, desc = "Peek Definition", has = "definition" },
            { "gP", peek.peek_implementation, desc = "Peek Implementation", has = "implementation" },
            { "gr", picker("lsp_references"), desc = "References", nowait = true },
            { "gI", picker("lsp_implementations"), desc = "Goto Implementation" },
            { "gy", picker("lsp_typedefs"), desc = "Goto T[y]pe Definition" },
            { "gD", picker("lsp_declarations"), desc = "Goto Declaration" },
          },
        },
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
