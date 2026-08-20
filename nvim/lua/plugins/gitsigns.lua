return {
  "lewis6991/gitsigns.nvim",
  opts = function(_, opts)
    local original_on_attach = opts.on_attach
    local hunk_nav = require("config.git_hunk_nav")

    local function abs_path(path)
      local p = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
      return vim.uv.fs_realpath(p) or p
    end

    local function existing_file(path)
      local stat = vim.uv.fs_stat(path)
      return stat and stat.type == "file" and path or nil
    end

    local function files_from_git_explorer()
      if not package.loaded["neo-tree"] then return {} end
      local ok, manager = pcall(require, "neo-tree.sources.manager")
      if not ok then return {} end
      local state = manager.get_state("git_status")
      if not (state and state.tree and state.winid and vim.api.nvim_win_is_valid(state.winid)) then return {} end

      local files = {}
      local function walk(parent_id)
        for _, node in ipairs(state.tree:get_nodes(parent_id)) do
          if node.type == "file" then
            local path = existing_file(abs_path(node.path or node:get_id()))
            if path then files[#files + 1] = path end
          end
          if node:has_children() then walk(node:get_id()) end
        end
      end
      walk()
      return files
    end

    local function files_from_git_status()
      local name = vim.api.nvim_buf_get_name(0)
      local start = name ~= "" and name or vim.uv.cwd()
      local root = start and vim.fs.root(start, ".git")
      if not root then return {} end

      -- ponytail: porcelain scan is O(dirty files) per file jump; switch to
      -- gitsigns Repo:files_changed if a 10k-file dirty tree ever hurts.
      local result = vim.system({ "git", "-C", root, "status", "--porcelain=v1", "-z", "-uall" }, { text = true }):wait()
      if result.code ~= 0 or not result.stdout then return {} end

      local files = {}
      for _, rel in ipairs(hunk_nav.porcelain_paths(result.stdout)) do
        local path = existing_file(abs_path(root .. "/" .. rel))
        if path then files[#files + 1] = path end
      end
      return files
    end

    ---@return boolean
    local function review_transitioning()
      local review = package.loaded["config.review_mode"]
      return not not (review and type(review.is_stopping) == "function" and review.is_stopping())
    end

    local function changed_files()
      local review = package.loaded["config.review_mode"]
      if review and review.is_active() then return review.files() end

      local files = files_from_git_explorer()
      if #files > 0 then return files end
      return files_from_git_status()
    end

    local function reveal_in_git_explorer(path)
      if not package.loaded["neo-tree"] then return end
      local ok_manager, manager = pcall(require, "neo-tree.sources.manager")
      local ok_renderer, renderer = pcall(require, "neo-tree.ui.renderer")
      if not (ok_manager and ok_renderer) then return end
      local state = manager.get_state("git_status")
      if not (state and renderer.window_exists(state)) then return end
      renderer.focus_node(state, path, true)
    end

    local function apply_inline_preview_highlights()
      local highlights = {
        GitSignsAddInline = { fg = "#ffffff", bg = "#166534", bold = true },
        GitSignsChangeInline = { fg = "#ffffff", bg = "#92400e", bold = true },
        GitSignsDeleteInline = { fg = "#ffffff", bg = "#7f1d1d", bold = true, strikethrough = true },
        GitSignsAddVirtLnInline = { fg = "#ffffff", bg = "#166534", bold = true },
        GitSignsChangeVirtLnInline = { fg = "#ffffff", bg = "#92400e", bold = true },
        GitSignsDeleteVirtLnInline = { fg = "#ffffff", bg = "#7f1d1d", bold = true, strikethrough = true },
        GitSignsDeleteVirtLnInLine = { fg = "#ffffff", bg = "#7f1d1d", bold = true, strikethrough = true },
      }

      for group, highlight in pairs(highlights) do
        vim.api.nvim_set_hl(0, group, highlight)
      end
    end

    apply_inline_preview_highlights()

    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("gitsigns_inline_preview_highlights", { clear = true }),
      callback = apply_inline_preview_highlights,
    })

    local scroll_pause = {
      count = 0,
      previous_buf_scroll = nil,
      scroll = nil,
      was_enabled = false,
    }

    local function pause_snacks_scroll()
      local buffer = vim.api.nvim_get_current_buf()
      if scroll_pause.count == 0 then
        local ok, scroll = pcall(require, "snacks.scroll")

        scroll_pause.scroll = ok and scroll or nil
        scroll_pause.was_enabled = ok and scroll.enabled or false
        scroll_pause.previous_buf_scroll = vim.b[buffer].snacks_scroll

        vim.b[buffer].snacks_scroll = false

        if scroll_pause.was_enabled then scroll.disable() end
      end

      scroll_pause.count = scroll_pause.count + 1

      local restored = false
      return function()
        if restored then return end
        restored = true

        vim.defer_fn(function()
          scroll_pause.count = math.max(scroll_pause.count - 1, 0)
          if scroll_pause.count > 0 then return end

          if vim.api.nvim_buf_is_valid(buffer) then vim.b[buffer].snacks_scroll = scroll_pause.previous_buf_scroll end

          if scroll_pause.was_enabled and scroll_pause.scroll and not scroll_pause.scroll.enabled then scroll_pause.scroll.enable() end

          scroll_pause.previous_buf_scroll = nil
          scroll_pause.scroll = nil
          scroll_pause.was_enabled = false
        end, 120)
      end
    end

    ---@param gs table
    ---@param callback? fun(err?: string)
    local function preview_hunk(gs, callback)
      local review = package.loaded["config.review_mode"]
      if review and review.is_active() and type(review.preview_and_pin) == "function" then
        review.preview_and_pin(callback)
        return
      end
      gs.preview_hunk_inline(callback)
    end

    ---@param restore_scroll fun()
    ---@param callback? fun(err?: string)
    ---@param err? string
    local function finish_landing(restore_scroll, callback, err)
      restore_scroll()
      if callback then callback(err) end
    end

    ---@param gs? table
    ---@param direction "next"|"prev"
    ---@param restore_scroll fun()
    ---@param retries? integer
    ---@param callback? fun(err?: string)
    local function land_in_buffer(gs, direction, restore_scroll, retries, callback)
      local buf = vim.api.nvim_get_current_buf()
      local hunks = gs and gs.get_hunks(buf) or {}
      if not gs or #hunks == 0 then
        -- attach() resolving does not mean hunks exist yet: gitsigns fills them
        -- in a later async pass. Poll briefly before treating the file as
        -- untracked (where gitsigns never attaches and the file is one stop).
        retries = retries == nil and 20 or retries
        if gs and retries > 0 then
          vim.defer_fn(function()
            if vim.api.nvim_get_current_buf() == buf then
              land_in_buffer(gs, direction, restore_scroll, retries - 1, callback)
            else
              finish_landing(restore_scroll, callback, "buffer changed while landing")
            end
          end, 50)
          return
        end
        local lnum = direction == "next" and 1 or vim.api.nvim_buf_line_count(buf)
        pcall(vim.api.nvim_win_set_cursor, 0, { math.max(lnum, 1), 0 })
        finish_landing(restore_scroll, callback)
        return
      end
      gs.nav_hunk(direction == "next" and "first" or "last", {}, function(err)
        if err then
          finish_landing(restore_scroll, callback, err)
          return
        end
        preview_hunk(gs, function(preview_err)
          finish_landing(restore_scroll, callback, preview_err)
        end)
      end)
    end

    local function nav_hunk_without_scroll_animation(direction)
      if review_transitioning() then
        vim.api.nvim_echo({ { "Review mode is stopping", "WarningMsg" } }, false, {})
        return
      end

      local restore_scroll = pause_snacks_scroll()
      vim.defer_fn(restore_scroll, 800)

      local buffer = vim.api.nvim_get_current_buf()
      local gs = package.loaded.gitsigns
      local hunks = gs and gs.get_hunks(buffer) or {}
      local cursor = vim.api.nvim_win_get_cursor(0)
      if gs and hunk_nav.has_hunk(hunks, cursor[1], direction, vim.api.nvim_buf_line_count(buffer)) then
        gs.nav_hunk(direction, { wrap = false }, function()
          preview_hunk(gs)
          restore_scroll()
        end)
        return
      end

      local next_file = hunk_nav.adjacent_path(changed_files(), abs_path(vim.api.nvim_buf_get_name(buffer)), direction)
      if not next_file then
        vim.api.nvim_echo({ { "No more hunks", "WarningMsg" } }, false, {})
        restore_scroll()
        return
      end

      vim.cmd.edit(vim.fn.fnameescape(next_file))
      reveal_in_git_explorer(next_file)
      if not gs then
        land_in_buffer(nil, direction, restore_scroll)
        return
      end
      gs.attach({ bufnr = vim.api.nvim_get_current_buf() }, function()
        land_in_buffer(gs, direction, restore_scroll)
      end)
    end

    package.loaded["git_hunk_nav_actions"] = {
      nav = nav_hunk_without_scroll_animation,
      -- Right after :edit gitsigns has not attached yet, so get_hunks is nil;
      -- landing must wait for attach or the nav treats the file as hunk-less.
      ---@param direction "next"|"prev"
      ---@param callback? fun(err?: string)
      land = function(direction, callback)
        if review_transitioning() then
          if callback then callback("review mode is stopping") end
          return
        end

        local restore_scroll = pause_snacks_scroll()
        vim.defer_fn(restore_scroll, 800)
        local gs = package.loaded.gitsigns
        if not gs then
          land_in_buffer(nil, direction, restore_scroll, nil, callback)
          return
        end
        gs.attach({ bufnr = vim.api.nvim_get_current_buf() }, function(err)
          if err then
            finish_landing(restore_scroll, callback, err)
            return
          end
          land_in_buffer(gs, direction, restore_scroll, nil, callback)
        end)
      end,
    }

    local function map_hunk_nav(lhs, direction, diff_motion, desc, buffer)
      vim.keymap.set("n", lhs, function()
        if vim.wo.diff then
          vim.cmd.normal({ diff_motion, bang = true })
        else
          nav_hunk_without_scroll_animation(direction)
        end
      end, { buffer = buffer, desc = desc, silent = true })
    end

    -- gitsigns skips untracked buffers, so on_attach never maps ]h there.
    map_hunk_nav("]h", "next", "]c", "Next Hunk or File")
    map_hunk_nav("[h", "prev", "[c", "Prev Hunk or File")

    opts.on_attach = function(buffer)
      if original_on_attach then original_on_attach(buffer) end

      local function has_inline_preview()
        local ok, preview = pcall(require, "gitsigns.actions.preview")
        return ok and preview.has_preview_inline(buffer)
      end

      local function recenter_without_scroll_animation(command)
        local normal_command = vim.v.count > 0 and (vim.v.count .. command) or command

        if vim.v.count > 0 or not has_inline_preview() then
          vim.cmd.normal({ normal_command, bang = true })
          return
        end

        local restore_scroll = pause_snacks_scroll()
        vim.cmd.normal({ normal_command, bang = true })
        restore_scroll()
      end

      -- LazyVim defines these mappings inside gitsigns' on_attach.
      -- Re-map only hunk navigation so Snacks smooth scroll stays enabled globally,
      -- but is paused for this path because it clears inline previews via CursorMoved.
      map_hunk_nav("]h", "next", "]c", "Next Hunk or File", buffer)
      map_hunk_nav("[h", "prev", "[c", "Prev Hunk or File", buffer)

      for _, command in ipairs({ "zt", "zb", "zz" }) do
        vim.keymap.set("n", command, function()
          recenter_without_scroll_animation(command)
        end, { buffer = buffer, desc = "Recenter without clearing hunk preview", silent = true })
      end
    end
  end,
}
