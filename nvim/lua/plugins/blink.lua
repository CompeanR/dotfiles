return {
  {
    "saghen/blink.cmp",
    opts = function(_, opts)
      opts.keymap = opts.keymap or {}
      opts.keymap["<Tab>"] = {
        function(cmp)
          if cmp.snippet_active() then
            return cmp.accept()
          end
          return cmp.select_and_accept()
        end,
        "snippet_forward",
        "fallback",
      }

      opts.sources = opts.sources or {}
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.providers.snippets = opts.sources.providers.snippets or {}
      opts.sources.providers.snippets.min_keyword_length = function(ctx)
        local filetype = vim.bo[ctx.bufnr].filetype
        if filetype == "markdown" or filetype == "markdown.mdx" then
          return 4
        end
        return 0
      end

      opts.sources.per_filetype = opts.sources.per_filetype or {}
      opts.sources.per_filetype.markdown = { "snippets", "path" }
      opts.sources.per_filetype["markdown.mdx"] = { "snippets", "path" }
    end,
  },
}
