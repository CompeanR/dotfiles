local M = {}

-- Numbered marks are global, so they can jump across files like A-Z marks.
local mark_sequence = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }

M.mark_by_digit = {}
M.digit_by_mark = {}

for _, digit in ipairs(mark_sequence) do
  M.mark_by_digit[digit] = digit
  M.digit_by_mark[digit] = digit
end

local function run_normal(keys)
  vim.cmd.normal({ args = { keys }, bang = true })
  vim.cmd("redrawstatus")
end

local function clear_mark(mark)
  vim.cmd("delmarks " .. mark)
  vim.cmd("redrawstatus")
end

local function mark_at_cursor(mark)
  local pos = vim.fn.getpos("'" .. mark)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return pos[1] == vim.api.nvim_get_current_buf() and pos[2] == cursor[1] and pos[3] == cursor[2] + 1
end

function M.setup()
  if M._did_setup then return end
  M._did_setup = true

  for _, mark in ipairs(mark_sequence) do
    local digit = M.digit_by_mark[mark]

    vim.keymap.set("n", "m" .. digit, function()
      if mark_at_cursor(mark) then
        clear_mark(mark)
        return
      end

      run_normal("m" .. mark)
    end, { desc = "Set numeric mark " .. digit })

    vim.keymap.set("n", "'" .. digit, function()
      run_normal("'" .. mark)
    end, { desc = "Jump to numeric mark line " .. digit })

    vim.keymap.set("n", "`" .. digit, function()
      run_normal("`" .. mark)
    end, { desc = "Jump to numeric mark position " .. digit })
  end
end

return M
