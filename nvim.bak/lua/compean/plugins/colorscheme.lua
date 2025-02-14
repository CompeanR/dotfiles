return {
  "sainnhe/gruvbox-material",
  priority = 1000,
  config = function()
    -- Set the color palette (available options: 'material', 'mix', 'original')
    vim.g.gruvbox_material_palette = "material"

    -- Set the background darkness ('hard', 'medium'(default), 'soft')
    vim.g.gruvbox_material_background = "hard"

    -- Set contrast for sidebars and floating windows
    vim.g.gruvbox_material_ui_contrast = "high"

    -- Set bold style for keywords
    vim.g.gruvbox_material_enable_bold = 1

    -- Set italic style for comments and HTML attributes
    vim.g.gruvbox_material_enable_italic = 1

    -- Set color for sign column background
    vim.g.gruvbox_material_sign_column_background = "none"

    -- Set dark background for current line number
    vim.g.gruvbox_material_current_word = "bold"

    -- Set the theme
    vim.cmd("colorscheme gruvbox-material")
  end,
}
