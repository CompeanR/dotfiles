return {
  "lewis6991/gitsigns.nvim",
  opts = function(_, opts)
    local original_on_attach = opts.on_attach

    local function apply_inline_preview_highlights()
      local highlights = {
        GitSignsAddInline = { fg = "#ffffff", bg = "#166534", bold = true },
        GitSignsChangeInline = { fg = "#ffffff", bg = "#92400e", bold = true },
        GitSignsDeleteInline = { fg = "#ffffff", bg = "#7f1d1d", bold = true, strikethrough = true },
        GitSignsAddVirtLnInline = { fg = "#ffffff", bg = "#166534", bold = true },
        GitSignsChangeVirtLnInline = { fg = "#ffffff", bg = "#92400e", bold = true },
        GitSignsDeleteVirtLnInline = { fg = "#ffffff", bg = "#7f1d1d", bold = true, strikethrough = true },
        GitSignsDeleteVirtLnInLine = { fg = "#ffffff", bg = "#7f1d1d", bold = true, strikethrough = true },
      }

      for group, highlight in pairs(highlights) do
        vim.api.nvim_set_hl(0, group, highlight)
      end
    end

    apply_inline_preview_highlights()

    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("gitsigns_inline_preview_highlights", { clear = true }),
      callback = apply_inline_preview_highlights,
    })

    opts.on_attach = function(buffer)
      if original_on_attach then original_on_attach(buffer) end

      local gs = package.loaded.gitsigns
      local scroll_pause = {
        count = 0,
        previous_buf_scroll = nil,
        scroll = nil,
        was_enabled = false,
      }

      local function pause_snacks_scroll()
        if scroll_pause.count == 0 then
          local ok, scroll = pcall(require, "snacks.scroll")

          scroll_pause.scroll = ok and scroll or nil
          scroll_pause.was_enabled = ok and scroll.enabled or false
          scroll_pause.previous_buf_scroll = vim.b[buffer].snacks_scroll

          vim.b[buffer].snacks_scroll = false

          if scroll_pause.was_enabled then scroll.disable() end
        end

        scroll_pause.count = scroll_pause.count + 1

        local restored = false
        return function()
          if restored then return end
          restored = true

          vim.defer_fn(function()
            scroll_pause.count = math.max(scroll_pause.count - 1, 0)
            if scroll_pause.count > 0 then return end

            if vim.api.nvim_buf_is_valid(buffer) then vim.b[buffer].snacks_scroll = scroll_pause.previous_buf_scroll end

            if scroll_pause.was_enabled and scroll_pause.scroll and not scroll_pause.scroll.enabled then scroll_pause.scroll.enable() end

            scroll_pause.previous_buf_scroll = nil
            scroll_pause.scroll = nil
            scroll_pause.was_enabled = false
          end, 120)
        end
      end

      local function nav_hunk_without_scroll_animation(direction)
        local restore_scroll = pause_snacks_scroll()

        gs.nav_hunk(direction, {}, function()
          gs.preview_hunk_inline()
          restore_scroll()
        end)

        -- Safety net in case gitsigns returns early and never invokes the callback.
        vim.defer_fn(restore_scroll, 500)
      end

      local function has_inline_preview()
        local ok, preview = pcall(require, "gitsigns.actions.preview")
        return ok and preview.has_preview_inline(buffer)
      end

      local function recenter_without_scroll_animation(command)
        local normal_command = vim.v.count > 0 and (vim.v.count .. command) or command

        if vim.v.count > 0 or not has_inline_preview() then
          vim.cmd.normal({ normal_command, bang = true })
          return
        end

        local restore_scroll = pause_snacks_scroll()
        vim.cmd.normal({ normal_command, bang = true })
        restore_scroll()
      end

      local function map_hunk_nav(lhs, direction, diff_motion, desc)
        vim.keymap.set("n", lhs, function()
          if vim.wo.diff then
            vim.cmd.normal({ diff_motion, bang = true })
          else
            nav_hunk_without_scroll_animation(direction)
          end
        end, { buffer = buffer, desc = desc, silent = true })
      end

      -- LazyVim defines these mappings inside gitsigns' on_attach.
      -- Re-map only hunk navigation so Snacks smooth scroll stays enabled globally,
      -- but is paused for this path because it clears inline previews via CursorMoved.
      map_hunk_nav("]h", "next", "]c", "Next Hunk")
      map_hunk_nav("[h", "prev", "[c", "Prev Hunk")

      for _, command in ipairs({ "zt", "zb", "zz" }) do
        vim.keymap.set("n", command, function()
          recenter_without_scroll_animation(command)
        end, { buffer = buffer, desc = "Recenter without clearing hunk preview", silent = true })
      end
    end
  end,
}
