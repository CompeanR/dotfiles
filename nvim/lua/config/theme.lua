-- gruvbox-material syntax on matte-black neutrals, with Pi/herdr's yellow accent.
-- Dark is the default; Omarchy's light.mode switches to stock gruvbox-material light.
local M = {}

M.colors = {
  bg = "#121212",
  panel = "#212121",
  element = "#292929",
  selection = "#333333",
  border = "#414141",
  fg = "#bebebe",
  comment = "#8a8a8d",
  muted = "#a5a5a5",
  accent = "#FFC107",
  scope = "#d8a657",
  insert = "#10B981",
  visual = "#c96b6b",
  replace = "#D35F5F",
  command = "#c98a5a",
}

local light_mode_path = vim.fn.expand("~/.local/state/omarchy/current/theme/light.mode")

function M.is_light()
  return vim.uv.fs_stat(light_mode_path) ~= nil
end

-- Only the neutrals: gruvbox's warm browns become matte-black greys, hues stay gruvbox.
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
    grey0 = "#6f6f72",
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
  vim.api.nvim_set_hl(0, "CursorLineNr", { fg = c.accent })
  vim.api.nvim_set_hl(0, "SnacksIndentScope", { fg = c.scope })
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
  local dim = { fg = c.comment, bg = "NONE" }
  return {
    normal = mode(c.accent),
    insert = mode(c.insert),
    visual = mode(c.visual),
    replace = mode(c.replace),
    command = mode(c.command),
    inactive = { a = dim, b = dim, c = dim },
  }
end

function M.setup()
  vim.g.gruvbox_material_background = "hard"
  vim.g.gruvbox_material_foreground = "mix"
  vim.g.gruvbox_material_ui_contrast = "high"
  vim.g.gruvbox_material_enable_bold = 1
  vim.g.gruvbox_material_enable_italic = 1
  vim.g.gruvbox_material_sign_column_background = "none"
  vim.g.gruvbox_material_current_word = "bold"
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
