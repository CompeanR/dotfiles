-- Keeps diffview usable on a small box (2 CPU / 8 GB).
--
-- Measured on a 5-file diff: stepping through 4 files left 12 loaded buffers,
-- 8 treesitter highlighters and 4 LSP attachments alive, none of them released.
-- On TSX files with tsserver and a pi popup competing for two cores, that is
-- what makes the editor freeze. With this module: 5 buffers, 1 highlighter,
-- 1 LSP attachment — flat instead of linear.
--
-- Two levers here:
--   1. Never run treesitter on the `diffview://` base pane — it is an old
--      revision nobody edits, and it doubles the highlighter count per file.
--   2. Close reviewed files once they scroll out of the review.

local M = {}

-- Real files that diffview opened during this session. Only these get closed —
-- a file the user already had open is left completely alone.
local opened_by_diffview = {}

-- Buffers the user had loaded before a review started. Snapshotted when the view
-- opens, so a file that was already on screen is never mistaken for ours.
local preexisting = {}

---Close reviewed files and drop stale diff buffers. Both are rebuilt on demand,
---so stepping back to an earlier file just reopens it.
local function reclaim()
  local shown = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    shown[vim.api.nvim_win_get_buf(win)] = true
  end

  local freed = 0

  -- A reviewed file that has scrolled off screen is done with: closing it frees
  -- the buffer contents, its treesitter parsers and its tsserver attachment in
  -- one step. Skipped when modified, so an edit made mid-review is never lost.
  for buf in pairs(opened_by_diffview) do
    if not vim.api.nvim_buf_is_valid(buf) then
      opened_by_diffview[buf] = nil
    elseif
      vim.api.nvim_buf_is_loaded(buf)
      and not shown[buf]
      and not preexisting[buf]
      and not vim.bo[buf].modified
    then
      pcall(vim.api.nvim_buf_delete, buf, { force = false, unload = false })
      opened_by_diffview[buf] = nil
      freed = freed + 1
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      not shown[buf]
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.api.nvim_buf_get_name(buf):match("^diffview://")
      -- Panels live under diffview:///panels/ and must survive.
      and not vim.api.nvim_buf_get_name(buf):match("^diffview:///panels/")
    then
      pcall(vim.api.nvim_buf_delete, buf, { force = true, unload = false })
      freed = freed + 1
    end
  end
  return freed
end

M.reclaim = reclaim

local group = vim.api.nvim_create_augroup("DiffviewPerf", { clear = true })

-- Snapshot what was already open before the review, so those buffers are exempt
-- from closing however many times they show up in the diff.
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "DiffviewViewOpened",
  callback = function()
    preexisting = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
        preexisting[buf] = true
      end
    end
  end,
})

-- The base pane carries a filetype so it gets syntax, which drags in treesitter.
-- Stopping the highlighter keeps the diff colors (those are extmarks/diff hl)
-- while dropping the parse cost.
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "DiffviewDiffBufWinEnter",
  callback = function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("^diffview://") then
        pcall(vim.treesitter.stop, buf)
      elseif name ~= "" then
        -- The working-tree pane: a real file, so remember it as ours to reclaim.
        opened_by_diffview[buf] = true
      end
    end
    -- Reclaim on each file step, so a long review stays flat instead of growing.
    vim.schedule(reclaim)
  end,
})

vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "DiffviewViewClosed",
  callback = function()
    vim.schedule(reclaim)
  end,
})

vim.api.nvim_create_user_command("DiffviewReclaim", function()
  vim.notify(("[diffview-perf] released %d buffers"):format(reclaim()))
end, { desc = "Unload diffview buffers that are no longer displayed" })

package.loaded["diffview_perf"] = M

return {}
