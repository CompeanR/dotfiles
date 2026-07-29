return {
  {
    "craftzdog/solarized-osaka.nvim",
    lazy = true,
    priority = 1000,
    opts = function()
      return {
        transparent = true,
      }
    end,
  },
  { "tahayvr/matteblack.nvim", lazy = false, priority = 1000 },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "matteblack",
    },
  },
  {
    "sainnhe/gruvbox-material",
    priority = 1000,
    config = function()
      -- Set the color palette (available options: 'material', 'mix', 'original')
      vim.g.gruvbox_material_palette = "mix"

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

      -- 2 (not 1) so floating windows are transparent too — at 1 only the main
      -- editor is, which leaves popups (pi review, pickers, hover) on a gray
      -- background instead of the terminal's.
      vim.g.gruvbox_material_transparent_background = 2

      -- Float background is chosen by float_style, independently of the setting
      -- above: the default branch paints floats bg3 (#3c3836) even when the rest
      -- of the UI is transparent. 'blend' links NormalFloat to Normal instead,
      -- so popups actually inherit the terminal background.
      vim.g.gruvbox_material_float_style = "blend"

      -- Set the theme
      vim.cmd("colorscheme gruvbox-material")
    end,
  },
}
