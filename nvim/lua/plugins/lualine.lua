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

    table.insert(opts.sections.lualine_x, 1, {
      function() return require("prm").statusline() end,
      cond = function() return package.loaded.prm ~= nil and require("prm").statusline() ~= "" end,
    })

    table.insert(opts.sections.lualine_x, 1, {
      function() return require("config.merges").statusline() end,
      cond = function()
        local merges = package.loaded["config.merges"]
        return merges ~= nil and merges.statusline() ~= ""
      end,
      color = function() return require("config.merges").statusline_color() end,
    })

    -- The PR picker's entries are multi-line, so hide fzf's selected-entry part there.
    local fzf = vim.deepcopy(require("lualine.extensions.fzf"))
    fzf.sections.lualine_y = { { fzf.sections.lualine_y[1], cond = function() return not vim.b.pr_picker end } }
    opts.extensions = vim.tbl_map(function(ext) return ext == "fzf" and fzf or ext end, opts.extensions or {})
  end,
}
