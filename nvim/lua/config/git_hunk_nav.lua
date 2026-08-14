-- Pure helpers for ]h / [h crossing into the next git-status file.
local M = {}

---@param files string[]
---@param current string
---@param direction "next"|"prev"
---@return string?
function M.adjacent_path(files, current, direction)
  local idx
  for i, path in ipairs(files) do
    if path == current then
      idx = i
      break
    end
  end
  if not idx then return end
  if direction == "next" then return files[idx + 1] end
  return files[idx - 1]
end

---@param hunks { added: { start: integer, count: integer? }, vend?: integer }[]|nil
---@param lnum integer
---@param direction "next"|"prev"
---@param line_count integer?
---@return boolean
function M.has_hunk(hunks, lnum, direction, line_count)
  if not hunks or #hunks == 0 then return false end

  if direction == "next" then
    local start = hunks[#hunks].added.start
    -- gitsigns treats cursor-on-EOF as already on a trailing delete hunk
    if line_count and lnum == line_count and start == line_count + 1 then return false end
    return start > lnum
  end

  local first = hunks[1]
  local vend = first.vend or (first.added.start + math.max((first.added.count or 1) - 1, 0))
  return lnum > math.max(vend, 1)
end

return M
