return {
  "olimorris/codecompanion.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    "hrsh7th/nvim-cmp",
  },
  opts = {
    strategies = {
      chat = { adapter = "deepseek" },
      inline = { adapter = "openai" },
    },
    adapters = {
      deepseek = function()
        return require("codecompanion.adapters").extend("deepseek", {
          env = {
            api_key = "",
          },
        })
      end,
      openai = function()
        return require("codecompanion.adapters").extend("openai", {
          env = {
            api_key = "",
          },
        })
      end,
    },
    keys = {
      vim.keymap.set({ "n", "v" }, "<C-m>", "<cmd>CodeCompanionActions<cr>", { noremap = true, silent = true }),
      vim.keymap.set({ "n", "v" }, "<leader>a", "<cmd>CodeCompanionChat Toggle<cr>", { noremap = true, silent = true }),
      vim.keymap.set("v", "ga", "<cmd>CodeCompanionChat Add<cr>", { noremap = true, silent = true }),
      vim.cmd([[cab cc CodeCompanion]]),
    },
  },
}
