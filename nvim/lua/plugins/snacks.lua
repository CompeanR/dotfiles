return {
  {
    "folke/snacks.nvim",
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
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

          statuscolumn.buf_signs = function(buf, wanted)
            local signs = original_buf_signs(buf, wanted)
            if not wanted.mark then return signs end

            local marks = vim.fn.getmarklist(buf)
            vim.list_extend(marks, vim.fn.getmarklist())

            for _, mark in ipairs(marks) do
              if mark.pos[1] == buf and mark.mark:match("^'[0-9]$") then
                local lnum = mark.pos[2]
                local text = mark.mark:sub(2)
                signs[lnum] = signs[lnum] or {}
                if not has_mark(signs[lnum], text) then
                  table.insert(signs[lnum], {
                    text = text,
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
