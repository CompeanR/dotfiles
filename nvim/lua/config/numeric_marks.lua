local M = {}

-- Digits are the interface; uppercase marks are the storage. Vim's own '0-'9
-- are the previously-exited-file marks: shada sets them on every exit, so
-- using them directly makes marks appear in the statuscolumn that were never
-- placed by hand. P-Y is never written by Vim, and stays global so the marks
-- still jump across files. A-O is left free for manual uppercase marks.
local digit_sequence = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
local mark_sequence = { "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y" }

M.mark_by_digit = {}
M.digit_by_mark = {}

for index, digit in ipairs(digit_sequence) do
  local mark = mark_sequence[index]
  M.mark_by_digit[digit] = mark
  M.digit_by_mark[mark] = digit
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

-- :delmarks 0-9 would hit Vim's numbered marks, not these.
function M.clear_all()
  clear_mark(mark_sequence[1] .. "-" .. mark_sequence[#mark_sequence])
end

function M.setup()
  if M._did_setup then return end
  M._did_setup = true

  vim.api.nvim_create_user_command("MarksClear", function()
    M.clear_all()
  end, { desc = "Delete all numeric marks" })

  for _, digit in ipairs(digit_sequence) do
    local mark = M.mark_by_digit[digit]

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
