-- Git review: file panel + per-file diff, with LSP live in both panes.
--
-- For branch review use three dots — :DiffviewOpen origin/main...HEAD — so the
-- diff is against the merge base, not the current tip of main.
--
-- --imply-local swaps a range end that points at HEAD for the file on disk.
-- Without it both panes are diffview:// blobs (buftype=nowrite) and no LSP
-- attaches; with it the right pane is the real file, so gd/hover/rename work
-- across the whole stack — no need to squash commits to review them together.
-- Cost: the right side is the working tree, so uncommitted edits show up too.
--
-- PR review: <leader>gP / :DiffviewPR — gh list → fetch pull/N/head → Diffview.
-- --imply-local only bites when the PR head is your own checked-out HEAD;
-- someone else's PR stays blob-only (nothing on disk to attach to).
--
-- diff2_vertical stacks A (old) above B (new). We flip that (new on top) and
-- collapse A to 1 line by default. `go` toggles A to a 50/50 split.
-- Don't close A — Diffview recover() recreates both panes if its winid dies.
-- Re-applied on WinResized so herdr / equalalways don't undo collapse or 50/50.

---@return boolean
local function old_pane_visible()
  return vim.t.diffview_old_visible == true
end

---Put Diff2Ver's new pane (B) above old (A); collapse A or equalize 50/50.
---@param view table
local function apply_diff2_layout(view)
  local layout = view.cur_layout
  -- Layouts store name as a string on the class (e.g. "diff2_vertical"),
  -- unlike views which expose class:name() as a method.
  if not layout or not layout.class or layout.class.name ~= "diff2_vertical" then
    return
  end
  local win_a, win_b = layout.a.id, layout.b.id
  if not (vim.api.nvim_win_is_valid(win_a) and vim.api.nvim_win_is_valid(win_b)) then
    return
  end

  -- Default create order leaves A (old) above B (new). Move B to the top.
  local row_a = vim.api.nvim_win_get_position(win_a)[1]
  local row_b = vim.api.nvim_win_get_position(win_b)[1]
  if row_b > row_a then
    vim.api.nvim_win_call(win_b, function()
      vim.cmd("wincmd K")
    end)
  end

  local total = vim.api.nvim_win_get_height(win_a) + vim.api.nvim_win_get_height(win_b)
  local show_old = old_pane_visible()
  if show_old then
    vim.wo[win_a].winfixheight = false
    vim.wo[win_b].winfixheight = false
    local half = math.max(1, math.floor(total / 2))
    -- Already ~equal → skip (avoids WinResized ↔ set_height feedback).
    if math.abs(vim.api.nvim_win_get_height(win_b) - half) <= 1 then
      return
    end
    vim.api.nvim_win_set_height(win_b, half)
    vim.api.nvim_win_set_height(win_a, math.max(1, total - half))
  else
    -- Already collapsed → skip.
    if vim.api.nvim_win_get_height(win_a) <= 1 then
      vim.wo[win_a].winfixheight = true
      return
    end
    vim.wo[win_a].winfixheight = true
    vim.wo[win_b].winfixheight = false
    vim.api.nvim_win_set_height(win_a, 1)
    vim.api.nvim_win_set_height(win_b, math.max(1, total - 1))
  end
end

local layout_pending = false

---Re-apply after Diffview / tmux / herdr finish their window math.
---@param view? table
local function schedule_layout(view)
  if layout_pending then
    return
  end
  layout_pending = true
  vim.schedule(function()
    layout_pending = false
    local v = view
    if not v then
      local ok, lib = pcall(require, "diffview.lib")
      v = ok and lib.get_current_view() or nil
    end
    if v then
      apply_diff2_layout(v)
    end
  end)
end

---<leader>b → toggle panel, then restore collapse/50/50 (equalalways flattens it).
local function toggle_files_keep_ratio()
  require("diffview.actions").toggle_files()
  schedule_layout()
end

---`go` → show/hide old (A) pane. Shown → 50/50; hidden → 1-line sliver.
local function toggle_old_pane()
  vim.t.diffview_old_visible = not old_pane_visible()
  schedule_layout()
end

---Resolve the remote's default branch — repos differ (main / master / develop).
---@return string|nil "origin/<branch>"
local function origin_default_branch()
  -- Written by `git clone`, but missing in clones made before the remote's
  -- default changed; `git remote set-head origin -a` refreshes it.
  local head = vim.fn.systemlist({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })[1]
  if vim.v.shell_error == 0 and head and head ~= "" then
    return vim.trim(head)
  end
  for _, name in ipairs({ "origin/main", "origin/master", "origin/develop" }) do
    vim.fn.system({ "git", "rev-parse", "--verify", "--quiet", name })
    if vim.v.shell_error == 0 then
      return name
    end
  end
  return nil
end

---<leader>gp → whole branch vs its merge base, with LSP (see --imply-local above).
local function diffview_open_base()
  local base = origin_default_branch()
  if not base then
    vim.notify("Diffview: no origin default branch found", vim.log.levels.ERROR)
    return
  end
  vim.cmd(("DiffviewOpen %s...HEAD --imply-local"):format(base))
end

---Open Diffview for one GitHub PR (fork-safe via pull/N/head).
---@param num string|number
---@param base string base branch name (e.g. main)
local function diffview_open_pr(num, base)
  num = tostring(num)
  local ref = "refs/diffview/pr/" .. num
  vim.notify("Fetching PR #" .. num .. "…")
  local fetch = vim.fn.system({
    "git",
    "fetch",
    "--quiet",
    "origin",
    "pull/" .. num .. "/head:" .. ref,
  })
  if vim.v.shell_error ~= 0 then
    vim.notify(vim.trim(fetch), vim.log.levels.ERROR)
    return
  end
  -- Keep origin/<base> fresh so the three-dot left side exists.
  vim.fn.system({ "git", "fetch", "--quiet", "origin", base })
  vim.cmd(("DiffviewOpen origin/%s...%s --imply-local"):format(base, ref))
end

---Fuzzy-pick an open PR and review it in Diffview.
local function diffview_pick_pr()
  if vim.fn.executable("gh") == 0 then
    vim.notify("gh CLI required", vim.log.levels.ERROR)
    return
  end
  local out = vim.fn.system({
    "gh",
    "pr",
    "list",
    "--limit",
    "50",
    "--json",
    "number,title,headRefName,baseRefName,author,isDraft",
  })
  if vim.v.shell_error ~= 0 then
    vim.notify(vim.trim(out), vim.log.levels.ERROR)
    return
  end
  local ok, prs = pcall(vim.json.decode, out)
  if not ok or type(prs) ~= "table" then
    vim.notify("gh pr list: bad JSON", vim.log.levels.ERROR)
    return
  end
  if #prs == 0 then
    vim.notify("No open PRs", vim.log.levels.INFO)
    return
  end

  -- ANSI like fzf-lua git commits (yellow SHA). Matching still uses field 1.
  local c = { y = "\27[33m", m = "\27[35m", r = "\27[0m" }
  local lines = {}
  for _, pr in ipairs(prs) do
    lines[#lines + 1] = string.format(
      "%s%d%s\t%s\t%s\t%s\t%s\t%s",
      c.y,
      pr.number,
      c.r,
      pr.title,
      pr.baseRefName,
      pr.headRefName,
      pr.author.login,
      pr.isDraft and (c.m .. "draft" .. c.r) or ""
    )
  end

  -- Default `gh pr view` queries classic Projects and often prints only the
  -- GraphQL deprecation warning. JSON + --jq skips that field and formats
  -- body/files; body text never hits the shell (jq reads JSON).
  -- \u001b escapes are ANSI for the fzf preview pane.
  local preview = [=[GH_PAGER=cat gh pr view {1} --json number,title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,files,url,isDraft -q '
"\u001b[1;33m#\(.number) \(.title)\u001b[0m" + (if .isDraft then " \u001b[35m[draft]\u001b[0m" else "" end),
"\u001b[34m\(.author.login)\u001b[0m  \u001b[36m\(.baseRefName)\u001b[0m ← \u001b[36m\(.headRefName)\u001b[0m",
"\u001b[32m+\(.additions)\u001b[0m \u001b[31m-\(.deletions)\u001b[0m  \(.changedFiles) files",
"\u001b[34m\(.url)\u001b[0m",
"",
(.body // "(no description)"),
"",
"\u001b[1mFILES\u001b[0m",
(.files[]? | "\u001b[32m+\(.additions)\u001b[0m \u001b[31m-\(.deletions)\u001b[0m  \(.path)")
' 2>/dev/null]=]

  require("fzf-lua").fzf_exec(lines, {
    prompt = "PR> ",
    preview = preview,
    fzf_opts = {
      ["--ansi"] = true,
      ["--delimiter"] = "\t",
      ["--with-nth"] = "1,2,5,6",
    },
    actions = {
      ["enter"] = function(selected)
        local line = require("fzf-lua.utils").strip_ansi_coloring(selected[1] or "")
        local num, _, base = line:match("^(%d+)\t([^\t]*)\t([^\t]*)")
        if num and base then
          diffview_open_pr(num, base)
        end
      end,
      ["ctrl-b"] = {
        fn = function(selected)
          local line = require("fzf-lua.utils").strip_ansi_coloring(selected[1] or "")
          local num = line:match("^(%d+)")
          if num then
            vim.fn.jobstart({ "gh", "pr", "view", num, "--web" }, { detach = true })
          end
        end,
        -- Keep the picker open when opening the browser.
        noclose = true,
      },
    },
  })
end

return {
  {
    "sindrets/diffview.nvim",
    -- DiffviewToggle is deliberately absent: it's defined in init() and would
    -- collide with the placeholder command lazy creates for `cmd` entries.
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose", "DiffviewPR" },
    keys = {
      -- Deliberately NOT <leader>gd: that is LazyVim's "Git Diff (files)" picker.
      -- Both would register lazy-load stubs and whichever plugin loads last wins,
      -- so the binding would be a race rather than a choice.
      { "<leader>gv", "<cmd>DiffviewToggle<cr>", desc = "Diffview: toggle (working tree)" },
      { "<leader>gV", "<cmd>DiffviewOpen HEAD~1<cr>", desc = "Diffview: last commit" },
      -- Lowercase = the local, everyday case; uppercase = wider or remote.
      -- gp is free unless lazyvim snacks_picker / octo extras are on (they aren't).
      { "<leader>gp", diffview_open_base, desc = "Diffview: branch vs default (PR diff)" },
      { "<leader>gP", diffview_pick_pr, desc = "Diffview: pick GitHub PR" },
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

      -- LazyVim defaults fillchars.diff to "╱" (diagonal hatch on DiffDelete
      -- filler). Blank it; the red DiffDelete bg still marks the gap.
      vim.opt.fillchars:append({ diff = " " })

      -- herdr prefix+z / equalalways can undo collapse or 50/50 — restore.
      vim.api.nvim_create_autocmd("WinResized", {
        group = vim.api.nvim_create_augroup("DiffviewLayoutRatio", { clear = true }),
        callback = function()
          schedule_layout()
        end,
      })

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

      vim.api.nvim_create_user_command("DiffviewPR", function(a)
        if a.args == "" then
          diffview_pick_pr()
          return
        end
        local out = vim.fn.system({
          "gh",
          "pr",
          "view",
          a.args,
          "--json",
          "number,baseRefName",
        })
        if vim.v.shell_error ~= 0 then
          vim.notify(vim.trim(out), vim.log.levels.ERROR)
          return
        end
        local pok, pr = pcall(vim.json.decode, out)
        if not pok or not pr then
          vim.notify("gh pr view: bad JSON", vim.log.levels.ERROR)
          return
        end
        diffview_open_pr(pr.number, pr.baseRefName)
      end, { nargs = "?", desc = "Diffview: review PR (fuzzy, or :DiffviewPR 123)" })
    end,
    opts = {
      -- Word-level highlighting inside changed lines; looks noisy on reindented
      -- or wrapped code because it lights up changed whitespace.
      enhanced_diff_hl = false,
      hooks = {
        -- Keep regular diff panes full-width on open; <leader>b still toggles
        -- the file panel. File history keeps its commit-navigation panel.
        -- schedule: panel close / Diffview's own resize must finish first.
        view_opened = function(view)
          if view.class:name() == "DiffView" then
            view.panel:close()
          end
          schedule_layout(view)
        end,
        view_post_layout = function(view)
          schedule_layout(view)
        end,
      },
      keymaps = {
        -- equalalways rebalances after toggle_files; restore collapse/50/50 after.
        view = {
          { "n", "<leader>b", toggle_files_keep_ratio, { desc = "Toggle the file panel" } },
          { "n", "go", toggle_old_pane, { desc = "Toggle old (base) diff pane" } },
        },
        file_panel = {
          { "n", "<leader>b", toggle_files_keep_ratio, { desc = "Toggle the file panel" } },
        },
        file_history_panel = {
          { "n", "<leader>b", toggle_files_keep_ratio, { desc = "Toggle the file panel" } },
        },
      },
      view = {
        -- disable_diagnostics: diagnostics on the base pane are noise (it's an
        -- old revision) and cost a full lint pass per file stepped through.
        -- gd/hover still work — this only turns off diagnostic display.
        -- Diffview names layouts after the pane arrangement: "vertical" panes
        -- are stacked across horizontal dividers.
        default = { layout = "diff2_vertical", disable_diagnostics = true },
        file_history = { layout = "diff2_vertical", disable_diagnostics = true },
        merge_tool = { layout = "diff3_vertical", disable_diagnostics = true },
      },
      file_panel = {
        listing_style = "tree",
        win_config = { position = "left", width = 34 },
      },
    },
  },
}
