-- Oil.nvim: Edit your filesystem like a buffer
-- URL: https://github.com/stevearc/oil.nvim
-- Quick cheatsheet (inside Oil buffer):
-- - Create file/dir: type new name in a new line, then :w
-- - Delete file/dir: place cursor on entry, press dd, then :w
-- - Rename/move: edit entry name/path, then :w
-- - Open entry: <CR>
-- - Open vertical/horizontal/tab: <C-s> / <C-v> / <C-t>
-- - Preview entry: <C-p>
-- - Go parent dir: -
-- - Toggle hidden files: g.
-- - Refresh: <C-r>
-- - Close Oil: q

return {
  "stevearc/oil.nvim",

  -- Load Oil when opening a directory or when using the keymap
  lazy = false,

  keys = {
    { "-", "<CMD>Oil<CR>", desc = "Open Oil (parent dir)" },
    { "_", function() vim.cmd("Oil " .. vim.fn.fnameescape(vim.fn.getcwd())) end, desc = "Open Oil (cwd)" },
    { "<leader>E", "<CMD>Oil --float<CR>", desc = "Open Oil (floating)" },
  },

  opts = {
    -- Oil will take over directory buffers (e.g. `vim .` or `:e src/`)
    default_file_explorer = true,

    -- Restore window options to previous values when leaving an oil buffer
    restore_win_options = true,

    -- Skip the confirmation popup for simple operations
    skip_confirm_for_simple_edits = false,

    -- Selecting a new/moved/renamed file or directory will prompt you to save changes first
    prompt_save_on_select_new_entry = true,

    -- Keymaps in oil buffer. Can be any value that `vim.keymap.set` accepts OR a table of keymap
    keymaps = {
      ["g?"] = "actions.show_help",
      ["<CR>"] = "actions.select",
      ["<C-t>"] = { "actions.select", opts = { tab = true }, desc = "Open in new tab" },
      ["<M-s>"] = { "actions.select", opts = { vertical = true }, desc = "Open in vertical split" },
      ["<M-v>"] = { "actions.select", opts = { horizontal = true }, desc = "Open in horizontal split" },
      ["<C-p>"] = "actions.preview",
      ["<C-c>"] = "actions.close",
      ["<C-r>"] = "actions.refresh",
      ["-"] = "actions.parent",
      ["_"] = "actions.open_cwd",
      ["`"] = "actions.cd",
      ["~"] = { "actions.cd", opts = { scope = "tab" }, desc = ":tcd to the current oil directory" },
      ["gs"] = "actions.change_sort",
      ["gx"] = "actions.open_external",
      ["gy"] = "actions.copy_to_system_clipboard",
      ["gp"] = "actions.paste_from_system_clipboard",
      ["gP"] = { "actions.paste_from_system_clipboard", opts = { delete_original = true } },
      ["g."] = "actions.toggle_hidden",
      ["g\\"] = "actions.toggle_trash",
      -- Quick quit
      ["q"] = "actions.close",
    },

    -- Set to false to disable all of the above keymaps
    use_default_keymaps = false,

    view_options = {
      -- Show files and directories that start with "." by default
      show_hidden = true,
      -- This function defines what is considered a "hidden" file
      is_hidden_file = function(name, bufnr) return vim.startswith(name, ".") end,
      -- This function defines what will never be shown, even when `show_hidden` is set
      is_always_hidden = function(name, bufnr) return name == ".." or name == ".git" end,
      -- Natural sort order for files and directories
      natural_order = true,
      case_insensitive = false,
      sort = {
        -- sort order can be "asc" or "desc"
        -- see :help oil-columns to see which columns are sortable
        { "type", "asc" },
        { "name", "asc" },
      },
    },

    -- Configuration for the floating window in oil.open_float
    float = {
      -- Padding around the floating window
      padding = 2,
      max_width = 100,
      max_height = 30,
      border = "rounded",
      win_options = {
        winblend = 0,
      },
      -- preview_split: Split direction: "auto", "left", "right", "above", "below".
      preview_split = "auto",
      -- This is the config that will be passed to nvim_open_win.
      -- Change values here to customize the layout
      override = function(conf) return conf end,
    },

    -- Configuration for the actions floating preview window
    preview = {
      -- Width dimensions can be integers or a float between 0 and 1 (e.g. 0.4 for 40%)
      -- min_width and max_width can be a single value or a list of mixed integer/float types.
      max_width = 0.9,
      -- min_width = {40, 0.4} means "at least 40 columns, or at least 40% of total"
      min_width = { 40, 0.4 },
      -- optionally define an integer/float for the exact width of the preview window
      width = nil,
      -- Height dimensions can be integers or a float between 0 and 1 (e.g. 0.4 for 40%)
      max_height = 0.9,
      min_height = { 5, 0.1 },
      -- optionally define an integer/float for the exact height of the preview window
      height = nil,
      border = "rounded",
      win_options = {
        winblend = 0,
      },
      -- Whether the preview window is automatically updated when the cursor is moved
      update_on_cursor_moved = true,
    },

    -- Configuration for the floating progress window
    progress = {
      max_width = 0.9,
      min_width = { 40, 0.4 },
      width = nil,
      max_height = { 10, 0.9 },
      min_height = { 5, 0.1 },
      height = nil,
      border = "rounded",
      minimized_border = "none",
      win_options = {
        winblend = 0,
      },
    },

    -- Configuration for the floating SSH window
    ssh = {
      border = "rounded",
    },
  },

  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },

  config = function(_, opts)
    require("oil").setup(opts)
    local uv = vim.uv or vim.loop

    local function url_unescape(s)
      return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
    end

    local function get_clipboard_paths()
      local cmd
      local handler
      if vim.fn.has("mac") == 1 then
        cmd = {
          "osascript",
          "-e",
          "on run",
          "-e",
          "POSIX path of (the clipboard as «class furl»)",
          "-e",
          "end run",
        }
        handler = function(lines)
          local ret = {}
          for _, line in ipairs(lines) do
            if line and line:match("%S") then table.insert(ret, line) end
          end
          return ret
        end
      elseif vim.fn.has("unix") == 1 then
        local session = (vim.env.XDG_SESSION_TYPE or ""):lower()
        if session:find("x11") then
          cmd = { "xclip", "-o", "-selection", "clipboard", "-t", "text/uri-list" }
        elseif session:find("wayland") then
          cmd = { "wl-paste", "-t", "text/uri-list" }
        else
          return nil, "Unsupported desktop session for system clipboard"
        end
        handler = function(lines)
          local ret = {}
          for _, line in ipairs(lines) do
            local path = line:match("^file://(.+)$")
            if path then table.insert(ret, url_unescape(path)) end
          end
          return ret
        end
      else
        return nil, "System clipboard merge paste unsupported on this OS"
      end

      if vim.fn.executable(cmd[1]) == 0 then return nil, string.format("Missing executable: %s", cmd[1]) end
      local out = vim.fn.systemlist(cmd)
      if vim.v.shell_error ~= 0 then return nil, "Failed reading system clipboard" end
      return handler(out), nil
    end

    local function merge_paths_into_oil_dir()
      local oil = require("oil")
      local target_dir = oil.get_current_dir()
      if not target_dir then
        vim.notify("gM only works inside an oil buffer", vim.log.levels.WARN)
        return
      end

      local paths, err = get_clipboard_paths()
      if err then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end
      if not paths or #paths == 0 then
        vim.notify("No valid file:// paths in clipboard", vim.log.levels.WARN)
        return
      end

      local has_rsync = vim.fn.executable("rsync") == 1
      local merged = 0
      for _, src in ipairs(paths) do
        src = src:gsub("/+$", "")
        local stat = uv.fs_stat(src)
        if stat then
          local name = vim.fs.basename(src)
          local dest_path = target_dir .. name

          if stat.type == "directory" then
            vim.fn.mkdir(dest_path, "p")
            local cmd = has_rsync and { "rsync", "-a", "--", src .. "/", dest_path .. "/" }
              or { "cp", "-a", "--", src .. "/.", dest_path .. "/" }
            vim.fn.system(cmd)
            if vim.v.shell_error ~= 0 then
              vim.notify(string.format("Merge failed: %s", src), vim.log.levels.ERROR)
              return
            end
          else
            local cmd = has_rsync and { "rsync", "-a", "--", src, dest_path }
              or { "cp", "-f", "--", src, dest_path }
            vim.fn.system(cmd)
            if vim.v.shell_error ~= 0 then
              vim.notify(string.format("Merge failed: %s", src), vim.log.levels.ERROR)
              return
            end
          end

          merged = merged + 1
        else
          vim.notify(string.format("Source no longer exists: %s", src), vim.log.levels.WARN)
        end
      end

      require("oil.actions").refresh.callback({ force = true })
      local backend = has_rsync and "rsync" or "cp"
      vim.notify(string.format("Merged %d item(s) from clipboard via %s", merged, backend))
    end

    -- Custom autocmds for Oil
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "oil",
      callback = function()
        -- Set local options for oil buffers
        vim.opt_local.colorcolumn = ""
        vim.opt_local.signcolumn = "no"
        vim.keymap.set("n", "gM", merge_paths_into_oil_dir, {
          buffer = 0,
          desc = "Oil merge clipboard paths into current dir",
        })

        -- Auto-save when leaving oil buffer with changes
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = 0,
          callback = function()
            if vim.bo.modified then vim.cmd("silent! write") end
          end,
        })
      end,
    })

    -- Global keymap to open Oil in current buffer's directory
    vim.keymap.set("n", "<leader>-", function()
      local oil = require("oil")
      local current_buf = vim.api.nvim_get_current_buf()
      local current_file = vim.api.nvim_buf_get_name(current_buf)

      if current_file and current_file ~= "" then
        local dir = vim.fn.fnamemodify(current_file, ":h")
        oil.open(dir)
      else
        oil.open()
      end
    end, { desc = "Open Oil in current file's directory" })

  end,
}
