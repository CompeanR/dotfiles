local M = {}
local unpack_fn = table.unpack or unpack

local function trim(str)
  return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decode_uri_fragment(str)
  return (str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function normalize_anchor(anchor)
  local normalized = anchor:lower()
  normalized = normalized:gsub("[^%w%s_-]", "")
  normalized = normalized:gsub("%s+", "-")
  normalized = normalized:gsub("%-+", "-")
  normalized = normalized:gsub("^%-+", "")
  normalized = normalized:gsub("%-+$", "")
  return normalized
end

local function heading_slug(heading)
  local text = trim(heading)
  text = text:gsub("`", "")
  text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
  return normalize_anchor(text)
end

local function find_link_under_cursor(line, col1)
  local start = 1
  while true do
    local s, e = line:find("%b[]%b()", start)
    if not s then
      return nil
    end
    if col1 >= s and col1 <= e then
      local whole = line:sub(s, e)
      local target = whole:match("^%b[]%((.*)%)$")
      if target then
        target = trim(target)
        if target:sub(1, 1) == "<" and target:sub(-1) == ">" then
          target = target:sub(2, -2)
        end
        return target
      end
    end
    start = e + 1
  end
end

local function split_target(target)
  if target:match("^%a[%w+.-]*://") then
    return nil, nil
  end
  if target:sub(1, 1) == "#" then
    return nil, target:sub(2)
  end
  local path, anchor = target:match("^(.-)#(.+)$")
  if path then
    return path, anchor
  end
  return target, nil
end

local function is_absolute_path(path)
  if not path or path == "" then
    return false
  end
  if path:sub(1, 1) == "/" then
    return true
  end
  if path:match("^[A-Za-z]:[\\/]") then
    return true
  end
  if path:match("^\\\\") then
    return true
  end
  return false
end

local function resolve_path(path)
  if not path or path == "" then
    return vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  end
  if is_absolute_path(path) then
    return vim.fs.normalize(path)
  end
  local current = vim.api.nvim_buf_get_name(0)
  local base = vim.fs.dirname(current)
  return vim.fs.normalize(base .. "/" .. path)
end

local function jump_to_anchor(anchor)
  if not anchor or anchor == "" then
    return
  end
  local wanted = normalize_anchor(decode_uri_fragment(anchor))
  if wanted == "" then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local seen = {}
  for idx, line in ipairs(lines) do
    local heading = line:match("^%s*#+%s+(.+)$")
    if heading then
      local slug = heading_slug(heading)
      if slug ~= "" then
        seen[slug] = (seen[slug] or 0) + 1
        local candidate = slug
        if seen[slug] > 1 then
          candidate = slug .. "-" .. (seen[slug] - 1)
        end
        if candidate == wanted then
          vim.api.nvim_win_set_cursor(0, { idx, 0 })
          return
        end
      end
    end
  end
end

local function fallback_gd()
  local has_def = #vim.lsp.get_clients({ bufnr = 0, method = "textDocument/definition" }) > 0
  if has_def then
    vim.lsp.buf.definition()
    return
  end
  vim.cmd("normal! gd")
end

function M.goto_link_or_definition()
  local row, col0 = unpack_fn(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  local target = find_link_under_cursor(line, col0 + 1)
  if not target then
    fallback_gd()
    return
  end

  local path, anchor = split_target(target)
  if path == nil and anchor == nil then
    fallback_gd()
    return
  end

  local resolved = resolve_path(path)
  if path and path ~= "" and not vim.uv.fs_stat(resolved) then
    vim.notify("markdown gd: file not found " .. resolved, vim.log.levels.WARN)
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(resolved))
  jump_to_anchor(anchor)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("markdown_gd", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "markdown", "markdown.mdx" },
    callback = function(args)
      vim.keymap.set("n", "gd", M.goto_link_or_definition, {
        buffer = args.buf,
        desc = "Goto Markdown Link Or Definition",
      })
    end,
  })
end

return M
