return {
  "hrsh7th/nvim-cmp",
  dependencies = {
    "kristijanhusak/vim-dadbod-completion", -- Ensure this plugin is installed
  },
  opts = function(_, opts)
    opts.experimental = {
      ghost_text = false,
    }
    -- Merge existing sources (if any) and add SQL-specific setup later
    return opts
  end,
  config = function(_, opts)
    local cmp = require("cmp")
    -- Apply global configuration
    cmp.setup(opts)

    -- SQL-specific configuration for dadbod
    cmp.setup.filetype("sql", {
      sources = cmp.config.sources({
        { name = "vim-dadbod-completion" },
        { name = "buffer" }, -- Optional: include buffer source
      }),
    })
  end,
}
