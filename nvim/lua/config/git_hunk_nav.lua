-- Pure helpers for ]h / [h crossing into the next git-status file.
local M = {}

---Repo-relative paths from `git status --porcelain=v1 -z`.
---For rename/copy, the first field is the new name and the next NUL field is the old name.
---@param stdout string
---@return string[]
function M.porcelain_paths(stdout)
  local files = {}
  local parts = vim.split(stdout, "\0", { plain = true, trimempty = true })
  local i = 1
  while i <= #parts do
    local status, file = parts[i]:match("^(..) (.+)$")
    i = i + 1
    if status then
      if status:find("[RC]") then i = i + 1 end
      files[#files + 1] = file
    end
  end
  return files
end

---@param files string[]
---@param current string
---@param direction "next"|"prev"
---@return string?
function M.adjacent_path(files, current, direction)
  if not files or #files == 0 then return end
  local idx
  for i, path in ipairs(files) do
    if path == current then
      idx = i
      break
    end
  end
  if idx then
    if direction == "next" then return files[idx + 1] end
    return files[idx - 1]
  end
  -- Not in the dirty list (Git Explorer closed, or a clean file): start at the
  -- first/last dirty file instead of giving up.
  if direction == "next" then return files[1] end
  return files[#files]
end

---@param hunks { added: { start: integer, count: integer? }, vend?: integer }[]|nil
---@param lnum integer
---@return { added: { start: integer, count: integer? }, vend?: integer }?
function M.hunk_at(hunks, lnum)
  if not hunks or #hunks == 0 then return end

  local previous
  for _, hunk in ipairs(hunks) do
    local start = hunk.added.start
    local count = hunk.added.count
    local finish = count == 0 and start or (hunk.vend or (start + math.max((count or 1) - 1, 0)))
    if lnum >= start and lnum <= finish then return hunk end
    if start > lnum then return previous or hunk end
    previous = hunk
  end
  return previous
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
