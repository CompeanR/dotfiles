-- Git review: file panel + per-file diff, with LSP live in both panes.
--
-- For branch review use three dots — :DiffviewOpen origin/main...HEAD — so the
-- diff is against the merge base, not the current tip of main.
return {
  {
    "sindrets/diffview.nvim",
    -- DiffviewToggle is deliberately absent: it's defined in init() and would
    -- collide with the placeholder command lazy creates for `cmd` entries.
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      -- Deliberately NOT <leader>gd: that is LazyVim's "Git Diff (files)" picker.
      -- Both would register lazy-load stubs and whichever plugin loads last wins,
      -- so the binding would be a race rather than a choice.
      { "<leader>gv", "<cmd>DiffviewToggle<cr>", desc = "Diffview: toggle (working tree)" },
      { "<leader>gV", "<cmd>DiffviewOpen HEAD~1<cr>", desc = "Diffview: last commit" },
      { "<leader>gm", "<cmd>DiffviewOpen origin/main...HEAD<cr>", desc = "Diffview: branch vs main" },
      { "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
      { "<leader>gF", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: branch history" },
    },
    init = function()
      -- linematch aligns changed blocks line-by-line instead of one big changed
      -- region. LazyVim already sets linematch:40, so replace rather than append.
      --
      -- PERF LEVER: {n} is a cutoff — hunks longer than n lines skip alignment.
      -- 60 is the value Nvim's own docs recommend, but ':h diffopt' warns of lag
      -- on very large hunks. Drop to 40 (or 0 to disable) if diffs feel sluggish.
      local diffopt = vim.tbl_filter(function(o)
        return not o:match("^linematch:")
      end, vim.opt.diffopt:get())
      table.insert(diffopt, "linematch:60")
      vim.opt.diffopt = diffopt

      -- gruvbox-material paints modified regions with its blue-tinted diff_blue.
      -- Re-point them at diff_yellow so add/change/delete read green/amber/red.
      -- Registered in init (not config) so it survives the colorscheme loading
      -- after this plugin spec is read.
      local function diff_hl()
        vim.api.nvim_set_hl(0, "DiffChange", { bg = "#4f422e" })
        vim.api.nvim_set_hl(0, "DiffText", { bg = "#7a6428", bold = true })
      end
      vim.api.nvim_create_autocmd("ColorScheme", { callback = diff_hl })
      diff_hl()

      -- diffview ships Open and Close but no toggle. Defined in init (not config)
      -- so the command exists before the plugin is lazy-loaded.
      vim.api.nvim_create_user_command("DiffviewToggle", function(a)
        local ok, lib = pcall(require, "diffview.lib")
        if ok and lib.get_current_view() then
          vim.cmd("DiffviewClose")
        else
          vim.cmd("DiffviewOpen " .. (a.args or ""))
        end
      end, { nargs = "*", desc = "Toggle Diffview" })
    end,
    opts = {
      -- Word-level highlighting inside changed lines; looks noisy on reindented
      -- or wrapped code because it lights up changed whitespace.
      enhanced_diff_hl = false,
      view = {
        -- disable_diagnostics: diagnostics on the base pane are noise (it's an
        -- old revision) and cost a full lint pass per file stepped through.
        -- gd/hover still work — this only turns off diagnostic display.
        default = { layout = "diff2_horizontal", disable_diagnostics = true },
        file_history = { layout = "diff2_horizontal", disable_diagnostics = true },
        merge_tool = { layout = "diff3_horizontal", disable_diagnostics = true },
      },
      file_panel = {
        listing_style = "tree",
        win_config = { position = "left", width = 34 },
      },
    },
  },
}
