-- Peek LSP locations in a K-style float, showing the real buffer so Treesitter
-- and semantic tokens apply. gp / gP shadow vim paste; Oil keeps buffer-local maps.
local M = {}

local peek_src_var = "lsp_peek_src"
local peek_method_var = "lsp_peek_method"
local peek_q_desc = "lsp-peek-close"

local function peek_existing(src, method)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win][peek_src_var] == src and vim.w[win][peek_method_var] == method then
      return win
    end
  end
end

local function close_peeks(src)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win][peek_src_var] == src and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
end

---@param loc table
---@return string? uri
---@return table? range
function M.location_range(loc)
  local uri = loc.targetUri or loc.uri
  -- Selection range is the symbol; targetRange can be the whole file.
  local range = loc.targetSelectionRange or loc.targetRange or loc.range
  return uri, range
end

---Fit the float to the current window, not leftover cursor rows.
---@param lines string[]
---@param win_w integer
---@param win_h integer
---@return integer width
---@return integer height
function M.float_size(lines, win_w, win_h)
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local max_width = math.max(20, math.floor(win_w * 0.9))
  local max_height = math.max(8, math.floor(win_h * 0.6))
  return math.min(width, max_width), math.min(math.max(#lines, 1), max_height)
end

local function unmap_peek_q(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if map.desc == peek_q_desc then
      pcall(vim.keymap.del, "n", "q", { buffer = bufnr })
      return
    end
  end
end

---@param loc table
---@param method string
function M.open(loc, method)
  local uri, range = M.location_range(loc)
  if not uri or not range then
    return
  end

  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  pcall(vim.treesitter.start, bufnr)

  local orig_win = vim.api.nvim_get_current_win()
  local orig_buf = vim.api.nvim_get_current_buf()
  local start_line = range.start.line
  local win_w = vim.api.nvim_win_get_width(orig_win)
  local win_h = vim.api.nvim_win_get_height(orig_win)
  local view = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + math.max(win_h, 8), false)
  local width, height = M.float_size(view, win_w, win_h)

  -- Place inside the source window without shrinking to leftover cursor rows.
  local winline = vim.fn.winline()
  local row
  if winline + height < win_h then
    row = winline
  elseif winline - 1 - height >= 0 then
    row = winline - 1 - height
  else
    row = math.max(0, math.floor((win_h - height) / 2))
  end
  local col = math.max(0, math.floor((win_w - width) / 2))

  local win = vim.api.nvim_open_win(bufnr, false, {
    relative = "win",
    win = orig_win,
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
    focusable = true,
    zindex = 50,
  })
  vim.wo[win].foldenable = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].statuscolumn = ""
  vim.wo[win].scrolloff = 0
  pcall(vim.api.nvim_win_set_cursor, win, { start_line + 1, range.start.character })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  vim.w[win][peek_src_var] = orig_buf
  vim.w[win][peek_method_var] = method

  local group = vim.api.nvim_create_augroup("LspPeek", { clear = true })
  local q_bufs = { orig_buf }
  if bufnr ~= orig_buf then
    q_bufs[#q_bufs + 1] = bufnr
  end

  local function unmap_all_q()
    for _, b in ipairs(q_bufs) do
      unmap_peek_q(b)
    end
  end

  local function close()
    unmap_all_q()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end

  -- q closes while the peek is open, including the first unfocused press.
  -- Unmapped on close so native q (macros) returns. Oil/source maps stay.
  for _, b in ipairs(q_bufs) do
    vim.keymap.set("n", "q", close, {
      buffer = b,
      nowait = true,
      silent = true,
      desc = peek_q_desc,
    })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      unmap_all_q()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  -- Delay so opening the float does not count as CursorMoved and dismiss it.
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertCharPre" }, {
      group = group,
      callback = function()
        if vim.api.nvim_get_current_win() == orig_win then
          close()
        end
      end,
    })
  end)
end

---Peek LSP location in a K-style float. Second press of the same key focuses/locks it.
function M.peek(method, not_found)
  local src = vim.api.nvim_get_current_buf()
  local existing = peek_existing(src, method)
  if existing and vim.api.nvim_win_is_valid(existing) then
    if vim.api.nvim_get_current_win() == existing then
      vim.cmd.wincmd("p")
    else
      vim.api.nvim_set_current_win(existing)
    end
    return
  end

  close_peeks(src)

  local win = vim.api.nvim_get_current_win()
  vim.lsp.buf_request_all(0, method, function(client)
    return vim.lsp.util.make_position_params(win, client.offset_encoding)
  end, function(results)
    for _, res in pairs(results) do
      local loc = res.result
      if loc then
        loc = vim.islist(loc) and loc[1] or loc
        if loc then
          M.open(loc, method)
          return
        end
      end
    end
    vim.notify(not_found, vim.log.levels.INFO)
  end)
end

function M.peek_definition()
  M.peek("textDocument/definition", "No definition found")
end

function M.peek_implementation()
  M.peek("textDocument/implementation", "No implementation found")
end

return M
