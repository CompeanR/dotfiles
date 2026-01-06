-- Example noice.nvim configuration file
return {
  "folke/noice.nvim",
  event = "VeryLazy",
  -- In your noice.nvim opts table
  opts = function(_, opts)
    opts.routes = opts.routes or {} -- Ensure the routes table exists

    -- Add this route to filter out the specific message
    table.insert(opts.routes, {
      filter = {
        event = "notify",
        find = "No information available", -- The exact message text
      },
      opts = { skip = true }, -- Tell noice to skip showing this notification
    })

    -- Make sure other opts like presets are still here
    opts.presets = opts.presets or {}
    opts.presets.lsp_doc_border = true

    -- Your other noice configurations...

    return opts
  end,
  dependencies = {
    -- Optional dependencies for noice
    "MunifTanjim/nui.nvim",
    -- "rcarriga/nvim-notify", -- Noice replaces nvim-notify
  },
}
