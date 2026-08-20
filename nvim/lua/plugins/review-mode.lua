return {
  "lewis6991/gitsigns.nvim",
  cmd = { "ReviewStart", "ReviewStop" },
  keys = {
    {
      "<leader>rv",
      function() require("config.review_mode").toggle() end,
      desc = "Toggle review vs origin/master",
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
    return opts
  end,
}
