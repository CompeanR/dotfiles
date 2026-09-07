return {
  -- Format .hurl on save. hurlfmt is the official formatter and ships with
  -- hurl itself, so there is nothing extra to install.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { hurl = { "hurlfmt" } },
      formatters = {
        hurlfmt = { command = "hurlfmt", args = {}, stdin = true },
      },
    },
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed or {}, { "hurl" })
    end,
  },

  -- Run the request under the cursor and read the response in a split.
  -- Keys are <leader>h* to stay clear of kulala's <leader>R*.
  {
    "jellydn/hurl.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "MunifTanjim/nui.nvim" },
    ft = "hurl",
    opts = {
      debug = false,
      show_notification = false,
      mode = "split",
      formatters = {
        json = { "jq" },
      },
    },
    keys = {
      -- Default to ToEntry: a file whose first request signs in cannot run a
      -- later entry on its own, and HurlRunnerAt fails with "Undefined variable".
      { "<leader>hh", "<cmd>HurlRunnerToEntry<CR>", ft = "hurl", desc = "Hurl: run up to cursor" },
      { "<leader>ha", "<cmd>HurlRunner<CR>", ft = "hurl", desc = "Hurl: run all requests" },
      { "<leader>ho", "<cmd>HurlRunnerAt<CR>", ft = "hurl", desc = "Hurl: run only this request" },
      { "<leader>hv", "<cmd>HurlVerbose<CR>", ft = "hurl", desc = "Hurl: run verbose" },
      { "<leader>hm", "<cmd>HurlToggleMode<CR>", ft = "hurl", desc = "Hurl: toggle split/popup" },
    },
  },
}
