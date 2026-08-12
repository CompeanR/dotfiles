---Whether the current tab is owned by Diffview.
---@return boolean
local function in_diffview()
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() ~= nil
end

local navigation_tab_var = "diffview_lsp_navigation_tab"

---Open or reuse the navigation tab associated with the current Diffview.
local function enter_navigation_tab()
  local diff_tab = vim.api.nvim_get_current_tabpage()
  local source_buf = vim.api.nvim_get_current_buf()
  local source_cursor = vim.api.nvim_win_get_cursor(0)
  local ok, navigation_tab = pcall(vim.api.nvim_tabpage_get_var, diff_tab, navigation_tab_var)

  if ok and type(navigation_tab) == "number" and vim.api.nvim_tabpage_is_valid(navigation_tab) then
    vim.api.nvim_set_current_tabpage(navigation_tab)
    vim.api.nvim_win_set_buf(0, source_buf)
    pcall(vim.api.nvim_win_set_cursor, 0, source_cursor)
  else
    -- Clone the source buffer so its LSP client remains attached, while the
    -- original review tab and both Diffview-managed panes stay untouched.
    vim.cmd("tab split")
    navigation_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_tabpage_set_var(diff_tab, navigation_tab_var, navigation_tab)
  end

  vim.cmd("diffoff")
  vim.wo.scrollbind = false
  vim.wo.cursorbind = false
end

---Open an fzf-lua LSP picker without replacing a Diffview-managed pane.
---@param provider string fzf-lua provider name
---@return function
local function diffview_safe_picker(provider)
  return function()
    if in_diffview() then
      enter_navigation_tab()
    end
    require("fzf-lua")[provider]({ jump1 = true, ignore_current_line = true })
  end
end

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },

      servers = {
        ["*"] = {
          keys = {
            { "gd", diffview_safe_picker("lsp_definitions"), desc = "Goto Definition", has = "definition" },
            { "gr", diffview_safe_picker("lsp_references"), desc = "References", nowait = true },
            { "gI", diffview_safe_picker("lsp_implementations"), desc = "Goto Implementation" },
            { "gy", diffview_safe_picker("lsp_typedefs"), desc = "Goto T[y]pe Definition" },
            { "gD", diffview_safe_picker("lsp_declarations"), desc = "Goto Declaration" },
          },
        },
        tailwindcss = {
          filetypes = {
            "templ",
            "vue",
            "html",
            "astro",
            "javascript",
            "typescript",
            "typescriptreact",
            "javascriptreact",
            "react",
            "htmlangular",
          },
        },
        intelephense = {
          filetypes = { "php", "blade" },
        },
      },
    },
  },
}
