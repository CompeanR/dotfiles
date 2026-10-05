return {
  {
    "lewis6991/gitsigns.nvim",
    cmd = { "ReviewStart", "ReviewStop", "ReviewNext", "ReviewPrev" },
    keys = {
      {
        "<leader>rv",
        function() require("config.review_mode").toggle() end,
        desc = "Toggle review vs origin/master",
      },
      {
        "<leader>rs",
        function() require("config.review_mode").stop() end,
        desc = "Stop review",
      },
      {
        "<leader>gp",
        function() require("config.review_pr").describe() end,
        desc = "PR: description and CI of this branch",
      },
      {
        "<leader>gR",
        function() require("config.review_pr").review_last() end,
        desc = "Review: back to the last reviewed PR",
      },
    },
    opts = function(_, opts)
      local commands = vim.api.nvim_get_commands({ builtin = false })
      if not commands.ReviewStart then
        pcall(vim.api.nvim_create_user_command, "ReviewStart", function(command)
          require("config.review_mode").start(command.args)
        end, { nargs = "?" })
      end
      if not commands.ReviewStop then
        pcall(vim.api.nvim_create_user_command, "ReviewStop", function()
          require("config.review_mode").stop()
        end, {})
      end
      if not commands.ReviewNext then
        pcall(vim.api.nvim_create_user_command, "ReviewNext", function()
          require("config.review_mode").change_file("next")
        end, {})
      end
      if not commands.ReviewPrev then
        pcall(vim.api.nvim_create_user_command, "ReviewPrev", function()
          require("config.review_mode").change_file("prev")
        end, {})
      end
      return opts
    end,
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    optional = true,
    opts = function(_, opts)
      -- Git Explorer (<leader>ge): same Ctrl-Q → commits → review as <leader>gd.
      opts.git_status = vim.tbl_deep_extend("force", opts.git_status or {}, {
        window = {
          mappings = {
            ["<C-q>"] = {
              function() require("config.review_mode").open_commits() end,
              desc = "Commits → review",
            },
          },
        },
      })
      return opts
    end,
  },
}
