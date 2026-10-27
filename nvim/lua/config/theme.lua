-- Matte-black on top of gruvbox-material, aligned with Pi, herdr and Omarchy.
-- Dark is the default; Omarchy's light.mode switches to stock gruvbox-material light.
local M = {}

M.colors = {
  bg = "#121212",
  panel = "#212121",
  element = "#292929",
  selection = "#333333",
  border = "#414141",
  fg = "#bebebe",
  bright = "#eaeaea",
  comment = "#8a8a8d",
  muted = "#a5a5a5",
  keyword = "#c96b6b",
  operator = "#c98a5a",
  func = "#d8a657",
  string = "#c8b48f",
  accent = "#FFC107",
  error = "#D35F5F",
  info = "#3B82F6",
  hint = "#1EA7A0",
  added = "#10B981",
}

local light_mode_path = vim.fn.expand("~/.local/state/omarchy/current/theme/light.mode")

function M.is_light()
  return vim.uv.fs_stat(light_mode_path) ~= nil
end

local function palette_override()
  local c = M.colors
  local palette = {
    bg_dim = c.bg,
    bg0 = c.bg,
    bg1 = c.panel,
    bg2 = c.panel,
    bg3 = c.element,
    bg4 = c.selection,
    bg5 = c.border,
    bg_statusline1 = c.bg,
    bg_statusline2 = c.panel,
    bg_statusline3 = c.element,
    bg_current_word = c.selection,
    bg_visual_red = "#3c2323",
    bg_visual_yellow = "#3a3020",
    bg_visual_green = "#1c3329",
    bg_visual_blue = "#1e2a3f",
    bg_red = c.error,
    bg_green = c.added,
    bg_yellow = c.accent,
    fg0 = c.fg,
    fg1 = c.bright,
    red = c.keyword,
    orange = c.operator,
    yellow = c.func,
    green = c.added,
    aqua = c.hint,
    blue = c.info,
    purple = c.keyword,
    grey0 = c.border,
    grey1 = c.comment,
    grey2 = c.muted,
  }
  for key, hex in pairs(palette) do
    palette[key] = { hex, "NONE" }
  end
  return palette
end

local function apply_overrides()
  if vim.o.background ~= "dark" then
    return
  end
  local c = M.colors
  local function hl(groups, spec)
    for _, group in ipairs(groups) do
      vim.api.nvim_set_hl(0, group, spec)
    end
  end

  hl({ "Keyword", "Conditional", "Repeat", "Statement", "Exception", "Include", "Typedef", "PreProc", "Define" }, { fg = c.keyword })
  hl({ "Number", "Float", "Boolean", "TSConstBuiltin", "@constant.builtin" }, { fg = c.keyword })
  hl({ "TSVariableBuiltin", "@variable.builtin" }, { fg = c.operator, italic = true })
  hl({ "Function", "TSFunction", "TSFunctionCall", "TSMethod", "TSMethodCall", "TSFuncBuiltin", "TSConstructor" }, { fg = c.func })
  hl({ "String", "Character", "TSString" }, { fg = c.string })
  hl({ "Type", "TSType", "TSTypeBuiltin", "TSTypeDefinition", "TSNamespace" }, { fg = c.bright, italic = true })
  hl({ "Identifier", "Constant", "TSField", "TSProperty", "TSParameter", "TSVariable" }, { fg = c.fg })
  hl({ "Comment", "SpecialComment", "TSComment" }, { fg = c.comment, italic = true })
  hl({ "CurrentWord", "LspReferenceText", "LspReferenceRead", "LspReferenceWrite" }, { bg = c.selection })

  local diagnostics = { Error = c.error, Warn = c.operator, Info = c.info, Hint = c.hint }
  for name, color in pairs(diagnostics) do
    hl({ "Diagnostic" .. name, "DiagnosticSign" .. name, "DiagnosticFloating" .. name, "DiagnosticVirtualText" .. name }, { fg = color })
    hl({ "DiagnosticUnderline" .. name }, { sp = color, undercurl = true })
  end

  hl({ "GitSignsAdd", "GitSignsAddNr" }, { fg = c.added })
  hl({ "GitSignsChange", "GitSignsChangeNr" }, { fg = c.func })
  hl({ "GitSignsDelete", "GitSignsDeleteNr" }, { fg = c.error })

  hl({ "CursorLineNr" }, { fg = c.accent })
  hl({ "Search" }, { fg = c.bg, bg = c.accent })
  hl({ "IncSearch", "CurSearch" }, { fg = c.bg, bg = c.operator })
  hl({ "FloatBorder", "WinSeparator" }, { fg = c.border })
end

function M.load()
  vim.o.background = M.is_light() and "light" or "dark"
  vim.g.gruvbox_material_colors_override = vim.o.background == "dark" and palette_override() or vim.empty_dict()
  vim.cmd.colorscheme("gruvbox-material")
end

function M.lualine()
  if vim.o.background ~= "dark" then
    return "gruvbox-material"
  end
  local c = M.colors
  local plain = { fg = c.fg, bg = "NONE" }
  local function mode(color)
    return { a = { fg = c.bg, bg = color, gui = "bold" }, b = { fg = c.muted, bg = "NONE" }, c = plain }
  end
  return {
    normal = mode(c.accent),
    insert = mode(c.added),
    visual = mode(c.keyword),
    replace = mode(c.error),
    command = mode(c.operator),
    inactive = { a = { fg = c.comment, bg = "NONE" }, b = { fg = c.comment, bg = "NONE" }, c = { fg = c.comment, bg = "NONE" } },
  }
end

function M.setup()
  vim.g.gruvbox_material_background = "hard"
  vim.g.gruvbox_material_foreground = "mix"
  vim.g.gruvbox_material_ui_contrast = "high"
  vim.g.gruvbox_material_enable_bold = 0
  vim.g.gruvbox_material_enable_italic = 1
  vim.g.gruvbox_material_sign_column_background = "none"
  vim.g.gruvbox_material_current_word = "grey background"
  -- 2 (not 1) so floats are transparent too; 'blend' links NormalFloat to Normal
  -- instead of painting floats bg3.
  vim.g.gruvbox_material_transparent_background = 2
  vim.g.gruvbox_material_float_style = "blend"

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("matte_black_overrides", { clear = true }),
    pattern = "gruvbox-material",
    callback = apply_overrides,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = vim.api.nvim_create_augroup("omarchy_light_mode", { clear = true }),
    callback = function()
      if (M.is_light() and "light" or "dark") ~= vim.o.background then
        M.load()
        local ok, lualine = pcall(require, "lualine")
        if ok then
          local config = lualine.get_config()
          config.options.theme = M.lualine()
          lualine.setup(config)
        end
      end
    end,
  })
end

return M
