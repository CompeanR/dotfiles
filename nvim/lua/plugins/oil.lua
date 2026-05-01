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
--
-- Multi-entry copy/paste (Oil-to-Oil, works across directories):
-- - Y       yank entry/selection (copy)   | works in normal + visual
-- - X       cut entry/selection (move)     | works in normal + visual
-- - P       paste from register into dir   | normal mode
--
-- System clipboard (Finder ↔ Oil):
-- - gy      copy to system clipboard       | works in normal + visual (macOS multi-path)
-- - gp/gM   paste from clipboard into dir  | direct fs copy (rsync/cp), multi-file on macOS
-- - gP      cut-paste from clipboard       | same as gp (Linux: oil buffer edit + :w)

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
      -- gy/gp/gP: set in autocmd with macOS multi-path support (see config function)
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

    ---------------------------------------------------------------------------
    -- Internal yank register: Oil-to-Oil multi-entry copy/cut/paste
    -- Works across directories without touching the system clipboard.
    ---------------------------------------------------------------------------
    ---@class OilYankRegister
    ---@field entries { name: string, src_dir: string }[]
    ---@field mode "copy"|"cut"
    local yank_register = { entries = {}, mode = "copy" }

    --- Collect entries under cursor (normal) or visual selection.
    ---@return { name: string, src_dir: string }[]|nil entries, string|nil error
    local function collect_oil_entries()
      local oil = require("oil")
      local dir = oil.get_current_dir()
      if not dir then return nil, "Only works inside a local oil buffer" end

      local entries = {}
      local mode = vim.api.nvim_get_mode().mode
      if mode == "v" or mode == "V" then
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local s_row, e_row = start_pos[2], end_pos[2]
        if s_row > e_row then s_row, e_row = e_row, s_row end
        for i = s_row, e_row do
          local entry = oil.get_entry_on_line(0, i)
          if entry then table.insert(entries, { name = entry.name, src_dir = dir }) end
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
      else
        local entry = oil.get_cursor_entry()
        if entry then table.insert(entries, { name = entry.name, src_dir = dir }) end
      end

      if #entries == 0 then return nil, "No entry under cursor" end
      return entries, nil
    end

    --- Yank (copy) entries to internal register. Works in normal + visual mode.
    local function oil_yank_entries()
      local entries, err = collect_oil_entries()
      if err then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      yank_register.entries = entries
      yank_register.mode = "copy"
      vim.notify(string.format("Yanked %d item(s) for copy", #entries))
    end

    --- Cut entries to internal register. Works in normal + visual mode.
    local function oil_cut_entries()
      local entries, err = collect_oil_entries()
      if err then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      yank_register.entries = entries
      yank_register.mode = "cut"
      vim.notify(string.format("Yanked %d item(s) for cut (move)", #entries))
    end

    --- Paste from internal register into current oil directory.
    --- Copies or moves using rsync/cp depending on availability.
    local function oil_paste_entries()
      local oil = require("oil")
      local target_dir = oil.get_current_dir()
      if not target_dir then
        vim.notify("Only works inside a local oil buffer", vim.log.levels.WARN)
        return
      end
      if #yank_register.entries == 0 then
        vim.notify("Nothing in yank register — use Y/X first", vim.log.levels.WARN)
        return
      end

      local has_rsync = vim.fn.executable("rsync") == 1
      local pasted = 0
      local is_move = yank_register.mode == "cut"

      for _, item in ipairs(yank_register.entries) do
        local src = (item.src_dir .. item.name):gsub("/+$", "")
        local stat = uv.fs_stat(src)
        if not stat then
          vim.notify(string.format("Source no longer exists: %s", src), vim.log.levels.WARN)
          goto continue
        end

        local dest_path = target_dir .. item.name

        if stat.type == "directory" then
          vim.fn.mkdir(dest_path, "p")
          if is_move then
            -- Move directory: rsync + rm, or mv
            if has_rsync then
              vim.fn.system({ "rsync", "-a", "--remove-source-files", "--", src .. "/", dest_path .. "/" })
              -- rsync --remove-source-files doesn't remove dirs, clean up empty src tree
              if vim.v.shell_error == 0 then vim.fn.system({ "find", src, "-type", "d", "-empty", "-delete" }) end
            else
              vim.fn.system({ "mv", "-f", "--", src, dest_path })
            end
          else
            local cmd = has_rsync and { "rsync", "-a", "--", src .. "/", dest_path .. "/" }
              or { "cp", "-a", "--", src .. "/.", dest_path .. "/" }
            vim.fn.system(cmd)
          end
        else
          if is_move then
            vim.fn.system({ "mv", "-f", "--", src, dest_path })
          else
            local cmd = has_rsync and { "rsync", "-a", "--", src, dest_path }
              or { "cp", "-f", "--", src, dest_path }
            vim.fn.system(cmd)
          end
        end

        if vim.v.shell_error ~= 0 then
          vim.notify(string.format("Failed: %s → %s", src, dest_path), vim.log.levels.ERROR)
          goto continue
        end

        pasted = pasted + 1
        ::continue::
      end

      -- After a cut, clear the register so items can't be "moved" twice
      if is_move then yank_register.entries = {} end

      require("oil.actions").refresh.callback({ force = true })
      local verb = is_move and "Moved" or "Copied"
      local backend = has_rsync and "rsync" or "cp/mv"
      vim.notify(string.format("%s %d item(s) via %s", verb, pasted, backend))
    end

    ---------------------------------------------------------------------------
    -- System clipboard: multi-path support for macOS
    ---------------------------------------------------------------------------
    local function url_unescape(s)
      return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
    end

    --- Copy selected Oil entries to the macOS system clipboard (multi-path).
    --- Uses an AppleScript that builds a list of POSIX files so Finder can paste them.
    local function mac_copy_to_clipboard()
      local entries, err = collect_oil_entries()
      if err then
        vim.notify(err, vim.log.levels.WARN)
        return
      end

      -- Build AppleScript that sets clipboard to a list of «POSIX file» items
      local posix_items = {}
      for _, item in ipairs(entries) do
        local full = (item.src_dir .. item.name):gsub("/+$", "")
        table.insert(posix_items, string.format('POSIX file "%s"', full))
      end
      local script = string.format(
        'set the clipboard to {%s}',
        table.concat(posix_items, ", ")
      )
      vim.fn.system({ "osascript", "-e", script })
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to copy to system clipboard", vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("Copied %d item(s) to system clipboard", #entries))
    end

    --- Read multiple paths from macOS system clipboard.
    --- Tries the file-list approach first, falls back to single «class furl».
    ---@return string[]|nil paths, string|nil error
    local function get_clipboard_paths_mac()
      -- Strategy 1: AppleScript that returns every file item as POSIX paths (newline-separated)
      local script = table.concat({
        'try',
        '  set fileList to the clipboard as «class furl»',
        '  -- clipboard may be a list or a single alias',
        '  set output to ""',
        '  try',
        '    repeat with f in fileList',
        '      set output to output & POSIX path of f & linefeed',
        '    end repeat',
        '  on error',
        '    set output to POSIX path of fileList',
        '  end try',
        '  return output',
        'on error',
        '  return ""',
        'end try',
      }, "\n")
      local out = vim.fn.system({ "osascript", "-e", script })
      if vim.v.shell_error ~= 0 then return nil, "Failed reading system clipboard" end
      local paths = {}
      for line in out:gmatch("[^\r\n]+") do
        line = line:gsub("/+$", "")
        if line ~= "" then table.insert(paths, line) end
      end
      if #paths > 0 then return paths, nil end
      return nil, "No file paths in clipboard"
    end

    --- Read clipboard paths cross-platform.
    ---@return string[]|nil paths, string|nil error
    local function get_clipboard_paths()
      if vim.fn.has("mac") == 1 then
        return get_clipboard_paths_mac()
      elseif vim.fn.has("unix") == 1 then
        local session = (vim.env.XDG_SESSION_TYPE or ""):lower()
        local cmd
        if session:find("x11") then
          cmd = { "xclip", "-o", "-selection", "clipboard", "-t", "text/uri-list" }
        elseif session:find("wayland") then
          cmd = { "wl-paste", "-t", "text/uri-list" }
        else
          return nil, "Unsupported desktop session for system clipboard"
        end
        if vim.fn.executable(cmd[1]) == 0 then return nil, string.format("Missing executable: %s", cmd[1]) end
        local out = vim.fn.systemlist(cmd)
        if vim.v.shell_error ~= 0 then return nil, "Failed reading system clipboard" end
        local paths = {}
        for _, line in ipairs(out) do
          local path = line:match("^file://(.+)$")
          if path then table.insert(paths, url_unescape(path)) end
        end
        return (#paths > 0) and paths or nil, (#paths > 0) and nil or "No file paths in clipboard"
      end
      return nil, "System clipboard paste unsupported on this OS"
    end

    --- Paste files from system clipboard into the current Oil directory (rsync/cp).
    --- Handles multiple files/folders on macOS and Linux.
    local function merge_paths_into_oil_dir()
      local oil = require("oil")
      local target_dir = oil.get_current_dir()
      if not target_dir then
        vim.notify("Only works inside an oil buffer", vim.log.levels.WARN)
        return
      end

      local paths, clip_err = get_clipboard_paths()
      if clip_err then
        vim.notify(clip_err, vim.log.levels.ERROR)
        return
      end
      if not paths or #paths == 0 then
        vim.notify("No valid file paths in clipboard", vim.log.levels.WARN)
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

    ---------------------------------------------------------------------------
    -- Oil autocmds and keymaps
    ---------------------------------------------------------------------------
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "oil",
      callback = function()
        -- Set local options for oil buffers
        vim.opt_local.colorcolumn = ""
        vim.opt_local.signcolumn = "no"

        local buf_opts = { buffer = 0, silent = true }

        -- Internal yank/paste (Oil-to-Oil, cross-directory, multi-entry)
        vim.keymap.set({ "n", "v" }, "Y", oil_yank_entries, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: yank entries to register (copy)",
        }))
        vim.keymap.set({ "n", "v" }, "X", oil_cut_entries, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: cut entries to register (move)",
        }))
        vim.keymap.set("n", "P", oil_paste_entries, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: paste from register into current dir",
        }))

        -- System clipboard (macOS multi-path aware)
        vim.keymap.set({ "n", "v" }, "gy", function()
          if vim.fn.has("mac") == 1 then
            mac_copy_to_clipboard()
          else
            require("oil.clipboard").copy_to_system_clipboard()
          end
        end, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: copy to system clipboard",
        }))
        vim.keymap.set("n", "gp", function()
          if vim.fn.has("mac") == 1 then
            -- Upstream «class furl» breaks with multi-file clipboard (-1700).
            -- Use our direct-fs merge instead.
            merge_paths_into_oil_dir()
          else
            require("oil.clipboard").paste_from_system_clipboard()
          end
        end, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: paste from system clipboard",
        }))
        vim.keymap.set("n", "gP", function()
          if vim.fn.has("mac") == 1 then
            merge_paths_into_oil_dir()
          else
            require("oil.clipboard").paste_from_system_clipboard(true)
          end
        end, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: cut-paste from system clipboard",
        }))
        vim.keymap.set("n", "gM", merge_paths_into_oil_dir, vim.tbl_extend("force", buf_opts, {
          desc = "Oil: merge clipboard paths into current dir (direct fs)",
        }))

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
