return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    -- Remove the clock from lualine_z
    opts.sections.lualine_z = {}

    opts.sections.lualine_c = {
      {
        "filename",
        path = 4,
        shorting_target = 40,
      },
    }

    opts.sections.lualine_x = opts.sections.lualine_x or {}
    table.insert(opts.sections.lualine_x, 1, {
      function()
        local review = package.loaded["config.review_mode"]
        return review and review.statusline() or ""
      end,
      cond = function() return (vim.g.review_mode_status or "") ~= "" end,
    })
  end,
}
