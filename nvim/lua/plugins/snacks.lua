return {
  {
    "folke/snacks.nvim",
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
          local numeric_marks = require("config.numeric_marks")
          local ok, statuscolumn = pcall(require, "snacks.statuscolumn")
          if not ok or statuscolumn._numeric_mark_patch then return end

          local original_buf_signs = statuscolumn.buf_signs

          ---@param items table[]
          ---@param text string
          ---@return boolean
          local function has_mark(items, text)
            for _, item in ipairs(items) do
              if item.type == "mark" and item.text == text then return true end
            end
            return false
          end

          ---@param items table[]
          ---@param text string
          local function remove_mark(items, text)
            for index = #items, 1, -1 do
              if items[index].type == "mark" and items[index].text == text then table.remove(items, index) end
            end
          end

          statuscolumn.buf_signs = function(buf, wanted)
            local signs = original_buf_signs(buf, wanted)
            if not wanted.mark then return signs end

            local marks = vim.fn.getmarklist(buf)

            for _, mark in ipairs(marks) do
              local mark_name = mark.mark:sub(2)
              local digit = numeric_marks.digit_by_mark[mark_name]

              if mark.pos[1] == buf and digit then
                local lnum = mark.pos[2]
                signs[lnum] = signs[lnum] or {}
                remove_mark(signs[lnum], mark_name)

                if not has_mark(signs[lnum], digit) then
                  table.insert(signs[lnum], {
                    text = digit,
                    texthl = "SnacksStatusColumnMark",
                    type = "mark",
                  })
                end
              end
            end

            return signs
          end

          statuscolumn._numeric_mark_patch = true
        end,
      })
    end,
    opts = function(_, opts)
      -- Snacks smooth scroll triggers CursorMoved during its animation.
      -- That clears gitsigns inline hunk previews immediately after ]h/[h navigation.
      opts.scroll = vim.tbl_deep_extend("force", opts.scroll or {}, {
        enabled = false,
      })

      local preview_fn = function(ctx)
        Snacks.picker.preview.preview(ctx)
        Snacks.util.wo(ctx.win, {
          wrap = true,
          linebreak = false,
          breakindent = true,
        })
      end

      opts.picker = opts.picker or {}
      opts.picker.sources = opts.picker.sources or {}
      opts.picker.sources.files = vim.tbl_deep_extend("force", opts.picker.sources.files or {}, {
        hidden = false,
      })
      opts.picker.sources.notifications = vim.tbl_deep_extend("force", opts.picker.sources.notifications or {}, {
        preview = preview_fn,
        win = {
          preview = {
            wo = {
              wrap = true,
              linebreak = false,
              breakindent = true,
            },
          },
        },
      })

      opts.styles = opts.styles or {}
      opts.styles.notification_history = vim.tbl_deep_extend("force", opts.styles.notification_history or {}, {
        wo = {
          wrap = true,
          linebreak = false,
          breakindent = true,
        },
      })
    end,
  },
}
