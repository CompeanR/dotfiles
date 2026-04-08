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
  end,
}
