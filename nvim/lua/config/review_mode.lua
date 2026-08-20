local M = {}

local active = false
local stopping = false
---@type fun()[]
local stop_callbacks = {}
local base_sha
local cached_files
local mapped_buffers = {}
local augroup_name = "review_mode"
-- Only <Tab>/<S-Tab> are bare: every other single letter shadows a core normal
-- mode command (a append, d delete, p paste, e word motion, q macro), and files
-- stay editable during a review.
-- <C-n>/<C-p> only shadow normal mode's duplicates of j/k, so they are free for
-- the next/previous mnemonic that bare n (search) and p (paste) cannot take.
local review_keys = { "<Tab>", "<S-Tab>", "]f", "[f", "<C-n>", "<C-p>", "<leader>rp", "<leader>rd", "<leader>rq" }

---@class ReviewTarget
---@field rev? string
---@field pr? integer

---@param arg? string
---@return ReviewTarget
function M.parse_target(arg)
  if not arg or arg == "" then return { rev = "origin/master" } end
  if arg:match("^%d+$") then return { pr = tonumber(arg) } end
  return { rev = arg }
end

---@return boolean
function M.is_active()
  return active or stopping
end

---@return boolean
function M.is_stopping()
  return stopping
end

---@return string?
function M.base()
  return base_sha
end

local function abs_path(path)
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return vim.uv.fs_realpath(normalized) or normalized
end

---@return string
function M.status()
  if not active or not base_sha then return "" end
  return "REVIEW vs " .. base_sha:sub(1, 7)
end

---@return string
function M.statusline()
  if not active or not base_sha then return "" end

  local parts = { M.status() }
  local files = M.files()
  local current = abs_path(vim.api.nvim_buf_get_name(0))
  for i, path in ipairs(files) do
    if path == current then
      parts[#parts + 1] = string.format("file %d/%d", i, #files)
      break
    end
  end

  local gs = package.loaded.gitsigns
  local hunks = gs and gs.get_hunks(0)
  if hunks and #hunks > 0 then
    local current_hunk = require("config.git_hunk_nav").hunk_at(hunks, vim.api.nvim_win_get_cursor(0)[1])
    for j, hunk in ipairs(hunks) do
      if hunk == current_hunk then
        parts[#parts + 1] = string.format("hunk %d/%d", j, #hunks)
        break
      end
    end
  end

  return table.concat(parts, " · ")
end

local function root()
  local name = vim.api.nvim_buf_get_name(0)
  local start = name ~= "" and name or vim.uv.cwd()
  return start and vim.fs.root(start, ".git") or nil
end

---@return string[]
function M.files()
  if cached_files then return cached_files end
  cached_files = {}
  if not base_sha then return cached_files end

  local repo = root()
  if not repo then return cached_files end
  local result = vim.system({ "git", "-C", repo, "diff", "--name-only", "-z", base_sha, "--" }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout then return cached_files end

  for _, rel in ipairs(vim.split(result.stdout, "\0", { plain = true, trimempty = true })) do
    local path = abs_path(repo .. "/" .. rel)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then cached_files[#cached_files + 1] = path end
  end
  return cached_files
end

local function notify_unavailable(name)
  vim.notify(name .. " unavailable", vim.log.levels.WARN)
end

-- gitsigns diffs buffer contents against the base, and `git checkout` carries
-- uncommitted work across branches, so local WIP shows up inside someone's PR
-- diff and is indistinguishable from it. Stash it for the duration instead.
local stash_ref
local stash_branch
local stash_repo

---@param repo string
---@return string?
local function current_branch(repo)
  local result = vim.system({ "git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout then return nil end
  local branch = vim.trim(result.stdout)
  return branch ~= "" and branch ~= "HEAD" and branch or nil
end

---@param repo string
---@return string?
local function checkout_target(repo)
  local branch = current_branch(repo)
  if branch then return branch end

  local result = vim.system({ "git", "-C", repo, "rev-parse", "HEAD" }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout then return nil end
  local sha = vim.trim(result.stdout)
  return sha ~= "" and sha or nil
end

---@param repo string
---@return string[]
local function dirty_paths(repo)
  local result = vim.system({ "git", "-C", repo, "status", "--porcelain=v1", "-z", "-uall" }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout then return {} end
  return require("config.git_hunk_nav").porcelain_paths(result.stdout)
end

---@param repo string
---@param ref string
---@return integer?
local function stash_index(repo, ref)
  local list = vim.system({ "git", "-C", repo, "stash", "list", "--format=%H" }, { text = true }):wait()
  if list.code ~= 0 or not list.stdout then return nil end
  for i, sha in ipairs(vim.split(vim.trim(list.stdout), "\n", { trimempty = true })) do
    if sha == ref then return i - 1 end
  end
end

---@param repo string
---@param target string
---@param selector string
---@return string
local function recovery_command(repo, target, selector)
  return ("git -C %s checkout %s && git -C %s stash pop %s"):format(
    vim.fn.shellescape(repo),
    vim.fn.shellescape(target),
    vim.fn.shellescape(repo),
    vim.fn.shellescape(selector)
  )
end

local function restore_working_tree()
  local ref = stash_ref
  local target = stash_branch
  local repo = stash_repo
  stash_ref = nil
  stash_branch = nil
  stash_repo = nil
  if not ref then return end

  local short = ref:sub(1, 7)
  local index = repo and stash_index(repo, ref)
  if not (repo and target and index) then
    local list = repo and ("git -C %s stash list"):format(vim.fn.shellescape(repo)) or "git stash list"
    local recover = repo and target and recovery_command(repo, target, "stash@{n}") or "git stash pop stash@{n}"
    vim.notify(
      ("stashed changes kept at SHA %s; find it with `%s`, then run `%s` with its stash index"):format(ref, list, recover),
      vim.log.levels.ERROR
    )
    return
  end

  -- The stash was taken before `gh pr checkout`, so popping it on the PR branch
  -- would move the work onto the wrong branch.
  if checkout_target(repo) ~= target then
    local checkout = vim.system({ "git", "-C", repo, "checkout", target }, { text = true }):wait()
    if checkout.code ~= 0 then
      vim.notify(
        ("stashed changes kept (%s): could not return to %s; run `%s`"):format(
          short,
          target,
          recovery_command(repo, target, ("stash@{%d}"):format(index))
        ),
        vim.log.levels.ERROR
      )
      return
    end
  end

  local selector = ("stash@{%d}"):format(index)
  local pop = vim.system({ "git", "-C", repo, "stash", "pop", selector }, { text = true }):wait()
  if pop.code ~= 0 then
    vim.notify(
      ("could not restore %s automatically; run `%s`"):format(short, recovery_command(repo, target, selector)),
      vim.log.levels.ERROR
    )
    return
  end
  vim.notify("restored stashed changes")
end

---Keep local WIP out of a PR review.
---@param repo string
---@param force_stash? boolean
---@return boolean continue
local function isolate_working_tree(repo, force_stash)
  local dirty = dirty_paths(repo)
  if #dirty == 0 then return true end

  local summary = ("%d uncommitted change%s would appear inside this PR review."):format(#dirty, #dirty == 1 and "" or "s")
  if not force_stash then
    -- confirm() has no answer without a UI, so headless runs just warn.
    if #vim.api.nvim_list_uis() == 0 then
      vim.notify(summary, vim.log.levels.WARN)
      return true
    end

    local choice = vim.fn.confirm(summary, "&Stash them\n&Review anyway\n&Cancel", 1, "Question")
    if choice ~= 1 then return choice == 2 end
  end

  local branch = checkout_target(repo)
  if not branch then
    vim.notify("cannot stash: could not resolve the current branch or HEAD commit", vim.log.levels.ERROR)
    return false
  end

  local stash_message = "nvim review mode"
  local stash = vim.system({ "git", "-C", repo, "stash", "push", "-u", "-m", stash_message }, { text = true }):wait()
  if stash.code ~= 0 then
    local message = vim.trim(stash.stderr or "")
    vim.notify(message ~= "" and message or "git stash failed", vim.log.levels.ERROR)
    return false
  end

  local ref = vim.system({ "git", "-C", repo, "rev-parse", "stash@{0}" }, { text = true }):wait()
  local resolved = ref.code == 0 and vim.trim(ref.stdout or "") or ""
  if resolved == "" then
    local list = ("git -C %s stash list"):format(vim.fn.shellescape(repo))
    local recover = recovery_command(repo, branch, "stash@{n}")
    vim.notify(
      ("git stash succeeded, but the '%s' stash ref could not be resolved; find it with `%s`, then run `%s` with its stash index"):format(
        stash_message,
        list,
        recover
      ),
      vim.log.levels.ERROR
    )
    return false
  end

  stash_ref = resolved
  stash_branch = branch
  stash_repo = repo
  vim.notify(("stashed %d change%s — restored on :ReviewStop"):format(#dirty, #dirty == 1 and "" or "s"))
  return true
end

-- gitsigns draws the inline preview, then registers a once-only
-- CursorMoved/InsertEnter/BufLeave autocmd to erase it, so it survives exactly
-- one cursor move. Review mode drops that eraser and redraws only when the
-- cursor enters a different hunk: the preview stays put while reading around it
-- (and while the pi popup has focus) without a second renderer duplicating the
-- deleted lines, and without the clear/redraw flicker of refreshing in place.
local previewed = {}
local redrawing = false
local preview_generation = 0

local CLEAR_PREVIEW_DESC = "Clear gitsigns inline preview"

local function drop_preview_eraser(buf)
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
    buffer = buf,
    event = { "CursorMoved", "InsertEnter", "BufLeave" },
  })
  if not ok then return end
  for _, autocmd in ipairs(autocmds) do
    if autocmd.desc == CLEAR_PREVIEW_DESC and autocmd.id then pcall(vim.api.nvim_del_autocmd, autocmd.id) end
  end
end

local function showing_preview(buf)
  local ok, preview = pcall(require, "gitsigns.actions.preview")
  return ok and preview.has_preview_inline(buf)
end

---@param hunk table
---@return integer, integer
local function hunk_bounds(hunk)
  local start = hunk.added.start
  local count = hunk.added.count or 1
  if count == 0 then return start, start end
  return start, hunk.vend or (start + math.max(count - 1, 0))
end

---@param hunk table
---@return string
local function hunk_signature(hunk)
  return table.concat({
    tostring(hunk.added.start),
    tostring(hunk.added.count),
    tostring(hunk.removed and hunk.removed.count),
    tostring(hunk.head),
  }, "\0")
end

---@param gs table
---@param buf integer
---@return table?
local function hunk_at_cursor(gs, buf)
  local hunks = gs.get_hunks(buf)
  if not hunks or #hunks == 0 then return end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  for _, hunk in ipairs(hunks) do
    local first, last = hunk_bounds(hunk)
    if lnum >= first and lnum <= last then return hunk end
  end
end

---@param hunk? table
---@param callback? fun(err?: string)
local function preview_and_pin(hunk, callback)
  local gs = package.loaded.gitsigns
  if not gs or type(gs.preview_hunk_inline) ~= "function" then
    if callback then callback("gitsigns unavailable") end
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  hunk = hunk or hunk_at_cursor(gs, buf)
  local signature = hunk and hunk_signature(hunk)
  preview_generation = preview_generation + 1
  local generation = preview_generation
  redrawing = true

  local completed = false
  local function complete(err)
    if completed then return end
    completed = true
    drop_preview_eraser(buf)

    if not active then
      local ns = vim.api.nvim_create_namespace("gitsigns_preview_inline")
      if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1) end
    elseif generation == preview_generation then
      previewed = signature and { buf = buf, signature = signature } or {}
      redrawing = false
    end

    if callback then callback(err) end
  end

  local ok, err = pcall(gs.preview_hunk_inline, complete)
  if not ok then complete(err) end
end

---@param callback? fun(err?: string)
function M.preview_and_pin(callback)
  if stopping then
    if callback then callback("review mode is stopping") end
    return
  end
  if not active then
    local gs = package.loaded.gitsigns
    if gs and type(gs.preview_hunk_inline) == "function" then gs.preview_hunk_inline(callback) end
    return
  end
  preview_and_pin(nil, callback)
end

local function follow_preview()
  if not active or redrawing then return end

  local gs = package.loaded.gitsigns
  if not gs or type(gs.preview_hunk_inline) ~= "function" then return end
  if vim.bo.buftype ~= "" or vim.fn.mode() ~= "n" then return end

  local buf = vim.api.nvim_get_current_buf()
  local current = hunk_at_cursor(gs, buf)
  -- Off a hunk: keep the last preview up rather than blanking the screen.
  if not current then return end
  if previewed.buf == buf and previewed.signature == hunk_signature(current) and showing_preview(buf) then return end

  -- preview_hunk_inline feedkeys()-scrolls for a hunk at the top of the buffer,
  -- which re-fires CursorMoved before rendering completes.
  preview_and_pin(current)
end

local function shared_nav(direction)
  local actions = package.loaded["git_hunk_nav_actions"]
  if actions and type(actions.nav) == "function" then
    actions.nav(direction)
    return
  end

  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    notify_unavailable("gitsigns")
    return
  end
  gs.nav_hunk(direction, { wrap = false }, function()
    M.preview_and_pin()
  end)
end

local function open_and_land(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local actions = package.loaded["git_hunk_nav_actions"]
  if actions and type(actions.land) == "function" then
    actions.land("next")
    return
  end
  shared_nav("next")
end

local function change_file(direction)
  local current = abs_path(vim.api.nvim_buf_get_name(0))
  local path = require("config.git_hunk_nav").adjacent_path(M.files(), current, direction)
  if not path then
    vim.notify("no more files", vim.log.levels.WARN)
    return
  end
  open_and_land(path)
end

local function apply_keymaps(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if not vim.bo[buf].buflisted or vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then return end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = "review: " .. desc, silent = true })
  end

  map("<Tab>", function() shared_nav("next") end, "next hunk")
  map("<S-Tab>", function() shared_nav("prev") end, "previous hunk")
  map("]f", function() change_file("next") end, "next changed file")
  map("[f", function() change_file("prev") end, "previous changed file")
  map("<C-n>", function() change_file("next") end, "next changed file")
  map("<C-p>", function() change_file("prev") end, "previous changed file")
  map("<leader>rp", M.preview_and_pin, "preview hunk")
  map("<leader>rd", function() require("gitsigns").diffthis(M.base()) end, "diff against base")
  map("<leader>rq", M.stop, "stop")
  mapped_buffers[buf] = true
end

---@class ReviewStartOpts
---@field stash? boolean

---@param arg? string
---@param opts? ReviewStartOpts
function M.start(arg, opts)
  if M.is_active() then
    M.stop(function() M.start(arg, opts) end)
    return
  end

  opts = opts or {}
  local repo = root()
  if not repo then
    vim.notify("not in a git repository", vim.log.levels.ERROR)
    return
  end

  local target = M.parse_target(arg)
  local rev = target.rev or "origin/master"
  if target.pr or opts.stash then
    if not isolate_working_tree(repo, opts.stash) then return end
  end
  if target.pr then
    local checkout = vim.system({ "gh", "pr", "checkout", tostring(target.pr) }, { cwd = repo, text = true }):wait()
    if checkout.code ~= 0 then
      local message = vim.trim(checkout.stderr or "")
      vim.notify(message ~= "" and message or "gh pr checkout failed", vim.log.levels.ERROR)
      restore_working_tree()
      return
    end
  end

  local merge_base = vim.system({ "git", "-C", repo, "merge-base", rev, "HEAD" }, { text = true }):wait()
  local base = merge_base.stdout and vim.trim(merge_base.stdout) or ""
  if merge_base.code ~= 0 or base == "" then
    local message = vim.trim(merge_base.stderr or "")
    vim.notify(message ~= "" and message or ("git merge-base failed for " .. rev), vim.log.levels.ERROR)
    restore_working_tree()
    return
  end

  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    notify_unavailable("gitsigns")
    restore_working_tree()
    return
  end

  base_sha = base
  cached_files = nil
  gs.change_base(base_sha, true)
  local files = M.files()
  if #files == 0 then
    gs.change_base(nil, true)
    base_sha = nil
    cached_files = nil
    vim.notify("no changes vs " .. base, vim.log.levels.WARN)
    restore_working_tree()
    return
  end

  active = true
  vim.g.review_mode_status = M.status()
  local group = vim.api.nvim_create_augroup(augroup_name, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(event)
      apply_keymaps(event.buf)
    end,
  })
  -- BufEnter/WinEnter cover returning from the pi popup, which clears the
  -- preview via BufLeave.
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter" }, {
    group = group,
    callback = follow_preview,
  })
  -- Quitting without :ReviewStop would otherwise strand the stash, leaving the
  -- work tree looking clean and the work seemingly gone.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = restore_working_tree,
  })
  apply_keymaps(vim.api.nvim_get_current_buf())

  open_and_land(files[1])
end

---@param callback? fun()
function M.stop(callback)
  if callback then stop_callbacks[#stop_callbacks + 1] = callback end
  if stopping then return end

  active = false
  stopping = true
  preview_generation = preview_generation + 1
  redrawing = false

  -- The eraser autocmd is gone, so a preview left on screen would never clear.
  local ns = vim.api.nvim_create_namespace("gitsigns_preview_inline")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1) end
  end
  previewed = {}
  pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
  for buf in pairs(mapped_buffers) do
    for _, lhs in ipairs(review_keys) do
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  mapped_buffers = {}
  vim.g.review_mode_status = ""
  restore_working_tree()

  ---@param err? string
  local function finish(err)
    stopping = false
    base_sha = nil
    cached_files = nil
    if err then vim.notify("could not reset gitsigns base: " .. err, vim.log.levels.ERROR) end
    vim.notify("review mode stopped")

    local callbacks = stop_callbacks
    stop_callbacks = {}
    for _, after_stop in ipairs(callbacks) do after_stop() end
  end

  local ok, gs = pcall(require, "gitsigns")
  if ok then
    gs.change_base(nil, true, finish)
  else
    finish()
  end
end

---@param arg? string
function M.toggle(arg)
  if M.is_active() then
    M.stop()
  else
    M.start(arg)
  end
end

return M
