local dynamic_width = math.floor(vim.o.columns * 0.20)

return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    log_level = "warn",
    window = {
      -- auto_expand_width = true,
      width = dynamic_width,
    },
    filesystem = {
      bind_to_cwd = true, -- Keep neo-tree root bound to cwd
      follow_current_file = {
        enabled = true,
        leave_dirs_open = false,
      },
      -- This prevents neo-tree from changing its root
      cwd_target = {
        sidebar = "global", -- Use global cwd, not per-window
        current = "global",
      },
      use_libuv_file_watcher = true,
    },
  },
}
