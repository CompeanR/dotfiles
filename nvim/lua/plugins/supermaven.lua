return {
  "supermaven-inc/supermaven-nvim",
  event = "InsertEnter",
  cmd = {
    "SupermavenUseFree",
    "SupermavenUsePro",
    "SupermavenToggle",
    "SupermavenStart",
    "SupermavenStop",
    "SupermavenStatus",
  },
  opts = {
    keymaps = {
      accept_suggestion = nil,
      clear_suggestion = nil,
      accept_word = nil,
    },
    disable_inline_completion = false,
    ignore_filetypes = { "bigfile", "snacks_input", "snacks_notif" },
  },
  config = function(_, opts)
    require("supermaven-nvim").setup(opts)

    -- Start disabled by default
    -- vim.schedule(function()
    --   local api = require("supermaven-nvim.api")
    --   if api.is_running() then api.stop() end
    -- end)

    -- Toggle keymap
    vim.keymap.set("n", "<leader>as", function() require("supermaven-nvim.api").toggle() end, { desc = "Toggle Supermaven AI" })
  end,
}
