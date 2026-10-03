local M = {}

local PREVIEW = [=[GH_PAGER=cat gh pr view {1} --json number,title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,files,url,isDraft -q '
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

local function check_state(check)
  if check.__typename == "StatusContext" then
    local state = check.state
    if state == "SUCCESS" then return "pass" end
    if state == "PENDING" or state == "EXPECTED" then return "pending" end
    return "fail"
  end
  if check.status ~= "COMPLETED" then return "pending" end
  local conclusion = check.conclusion
  if conclusion == "SUCCESS" or conclusion == "NEUTRAL" or conclusion == "SKIPPED" then return "pass" end
  if conclusion == "CANCELLED" then return "cancelled" end
  return "fail"
end

local function ci_status(pr)
  local icons = { pass = "✓", fail = "✗", pending = "●", cancelled = "–" }
  local rank = { fail = 4, pending = 3, pass = 2, cancelled = 1 }
  local counts = { pass = 0, fail = 0, pending = 0, cancelled = 0 }
  local order, states = {}, {}
  for _, check in ipairs(pr.statusCheckRollup or {}) do
    local name = check.name or check.context or "check"
    local state = check_state(check)
    if not states[name] then order[#order + 1] = name end
    if not states[name] or rank[state] > rank[states[name]] then states[name] = state end
  end
  local rows = {}
  for _, name in ipairs(order) do
    local state = states[name]
    counts[state] = counts[state] + 1
    rows[#rows + 1] = string.format("- %s %s", icons[state], name)
  end
  return counts, rows
end

local function ci_lines(pr)
  local counts, rows = ci_status(pr)
  local total = #rows
  local summary
  if total == 0 then
    summary = "no checks"
  elseif counts.fail > 0 then
    summary = string.format("✗ %d failed, %d passed", counts.fail, counts.pass)
  elseif counts.pending > 0 then
    summary = string.format("● %d running, %d passed", counts.pending, counts.pass)
  else
    summary = string.format("✓ %d/%d passed", counts.pass, total)
  end
  if counts.cancelled > 0 then summary = summary .. string.format(", %d cancelled", counts.cancelled) end
  if pr.mergeable == "CONFLICTING" then
    summary = summary .. " · conflicts"
  elseif pr.mergeable == "MERGEABLE" then
    summary = summary .. " · mergeable"
  end

  local lines = { "CI: " .. summary }
  if total > 0 then
    lines[#lines + 1] = ""
    vim.list_extend(lines, rows)
  end
  return lines
end

local DESCRIBE_FIELDS =
  "number,title,body,author,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,url,isDraft,state,statusCheckRollup,mergeable"

-- Cached per repo and HEAD commit: reopening is instant, a background refresh
-- keeps the CI line current once the cached copy is older than CACHE_TTL seconds.
local CACHE_TTL = 20
local cache = {}
local describe_win

local function now() return vim.uv.hrtime() / 1e9 end

local function system(args, dir, on_done)
  vim.system(args, { cwd = dir, text = true }, function(result)
    vim.schedule(function() on_done(result.code == 0, result.stdout or "", result.stderr or "") end)
  end)
end

local function view_pr(number, dir, on_done)
  local args = { "gh", "pr", "view" }
  if number then args[#args + 1] = tostring(number) end
  vim.list_extend(args, { "--json", DESCRIBE_FIELDS })
  system(args, dir, function(ok, out)
    local decoded = ok and select(2, pcall(vim.json.decode, out)) or nil
    on_done(type(decoded) == "table" and decoded or nil)
  end)
end

-- Review mode checks out the PR head detached, so `gh pr view` has no branch to
-- resolve: fall back to the PR (open first) that contains the HEAD commit.
local function fetch_pr(dir, sha, known_number, on_done)
  if known_number then return view_pr(known_number, dir, on_done) end
  view_pr(nil, dir, function(pr)
    if pr then return on_done(pr) end
    system({
      "gh", "api", "repos/{owner}/{repo}/commits/" .. sha .. "/pulls",
      "--jq", 'map(select(.state == "open"))[0].number // .[0].number',
    }, dir, function(ok, number)
      number = vim.trim(number)
      if not ok or number == "" or number == "null" then return on_done(nil) end
      view_pr(number, dir, on_done)
    end)
  end)
end

local function pr_lines(pr)
  local tag = pr.isDraft and " [draft]" or ""
  if pr.state and pr.state ~= "OPEN" then tag = tag .. " [" .. pr.state:lower() .. "]" end
  local lines = {
    string.format("# #%d %s%s", pr.number, pr.title, tag),
    string.format("%s  %s ← %s", pr.author.login, pr.baseRefName, pr.headRefName),
    string.format("+%d -%d  %d files", pr.additions, pr.deletions, pr.changedFiles),
    pr.url,
    "",
  }
  vim.list_extend(lines, ci_lines(pr))
  lines[#lines + 1] = ""
  local body = (type(pr.body) == "string" and pr.body ~= "") and pr.body or "(no description)"
  for _, line in ipairs(vim.split((body:gsub("\r", "")), "\n", { plain = true })) do
    lines[#lines + 1] = line
  end
  return lines
end

local function render(win, buf, pr)
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pr_lines(pr))
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_win_set_cursor, win, cursor)
  vim.api.nvim_win_set_config(win, { title = string.format(" PR #%d ", pr.number), title_pos = "center" })
end

local function open_window(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " PR ",
    title_pos = "center",
    footer = " q close · ^b browser · M merge when CI passes ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return win, buf
end

-- Squash-merges only a fresh, open, non-draft, conflict-free PR whose checks all
-- passed, and only the exact head commit that was read (--match-head-commit).
-- While checks run it can wait for them and merge only if they all pass.
local function merge_pr(dir, number, confirmed, after)
  view_pr(number, dir, function(pr)
    if not pr then return vim.notify("Could not read PR #" .. number, vim.log.levels.ERROR) end
    local function refuse(reason)
      vim.notify(string.format("Not merging #%d: %s", number, reason), vim.log.levels.WARN)
    end
    if pr.state ~= "OPEN" then return refuse("it is " .. pr.state:lower()) end
    if pr.isDraft then return refuse("it is a draft, mark it ready first") end
    if pr.mergeable == "CONFLICTING" then return refuse("it has conflicts") end
    local counts, rows = ci_status(pr)
    if counts.fail > 0 then return refuse(counts.fail .. " check(s) failed") end

    if counts.pending > 0 then
      if confirmed then return refuse("checks are still running") end
      local choice = vim.fn.confirm(
        string.format("#%d: CI is still running.\nWait for it, then squash and merge if all checks pass?", number),
        "&Wait and merge\n&Cancel", 2
      )
      if choice ~= 1 then return end
      vim.notify(string.format("Waiting for CI on #%d…", number))
      vim.fn.jobstart({ "gh", "pr", "checks", tostring(number), "--watch", "--fail-fast" }, {
        cwd = dir,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              merge_pr(dir, number, true, after)
            else
              vim.notify(string.format("CI did not pass: not merging #%d", number), vim.log.levels.WARN)
            end
          end)
        end,
      })
      return
    end

    if not confirmed then
      local note = #rows == 0 and "\n(no CI checks reported)" or ""
      local choice = vim.fn.confirm(
        string.format("Squash and merge #%d?\n%s%s", number, pr.title, note), "&Merge\n&Cancel", 2
      )
      if choice ~= 1 then return end
    end
    system({ "gh", "pr", "merge", tostring(number), "--squash", "--match-head-commit", pr.headRefOid }, dir,
      function(ok, _, err)
        if not ok then return vim.notify("Merge failed: " .. vim.trim(err), vim.log.levels.ERROR) end
        vim.notify(string.format("Merged #%d (squash). Clean up its worktree and branch by hand.", number))
        after()
      end)
  end)
end
M.merge_pr = merge_pr

function M.describe()
  if describe_win and vim.api.nvim_win_is_valid(describe_win) then
    vim.api.nvim_win_close(describe_win, true)
    describe_win = nil
    return
  end
  if vim.fn.executable("gh") == 0 then
    vim.notify("gh CLI required", vim.log.levels.ERROR)
    return
  end
  local dir = vim.fs.root(0, ".git") or vim.uv.cwd()
  local sha = vim.trim(vim.fn.system({ "git", "-C", dir, "rev-parse", "HEAD" }))
  if vim.v.shell_error ~= 0 then
    vim.notify("not in a git repository", vim.log.levels.ERROR)
    return
  end

  local key = dir .. ":" .. sha
  local entry = cache[key]
  local win, buf = open_window(entry and pr_lines(entry.pr) or { "Loading PR…" })
  describe_win = win
  if entry then
    vim.api.nvim_win_set_config(win, { title = string.format(" PR #%d ", entry.pr.number), title_pos = "center" })
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    describe_win = nil
  end
  local function refresh(pr)
    cache[key] = { pr = pr, at = now() }
    if vim.api.nvim_win_is_valid(win) then render(win, buf, pr) end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "<C-b>", function()
    local current = cache[key]
    if not current then return end
    vim.fn.jobstart({ "gh", "pr", "view", tostring(current.pr.number), "--web" }, { cwd = dir, detach = true })
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "M", function()
    local current = cache[key]
    if not current then return vim.notify("Still loading the PR", vim.log.levels.INFO) end
    merge_pr(dir, current.pr.number, false, function()
      view_pr(current.pr.number, dir, function(pr)
        if pr then refresh(pr) end
      end)
    end)
  end, { buffer = buf, nowait = true })

  if entry and now() - entry.at < CACHE_TTL then return end
  fetch_pr(dir, sha, entry and entry.pr.number, function(pr)
    if not pr then
      if not entry then
        close()
        vim.notify("No PR for this branch or commit", vim.log.levels.WARN)
      end
      return
    end
    refresh(pr)
  end)
end

function M.pick()
  if vim.fn.executable("gh") == 0 then
    vim.notify("gh CLI required", vim.log.levels.ERROR)
    return
  end
  local out = vim.fn.system({
    "gh", "pr", "list", "--limit", "50",
    "--json", "number,title,headRefName,baseRefName,author,isDraft",
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

  local c = { y = "\27[33m", m = "\27[35m", r = "\27[0m" }
  local lines = {}
  for _, pr in ipairs(prs) do
    lines[#lines + 1] = string.format(
      "%s%d%s\t%s\t%s\t%s\t%s\t%s",
      c.y, pr.number, c.r, pr.title, pr.baseRefName, pr.headRefName, pr.author.login,
      pr.isDraft and (c.m .. "draft" .. c.r) or ""
    )
  end

  local function plain(selected)
    return require("fzf-lua.utils").strip_ansi_coloring(selected[1] or "")
  end

  require("fzf-lua").fzf_exec(lines, {
    prompt = "PR> ",
    preview = PREVIEW,
    winopts = { preview = { wrap = true } },
    keymap = { fzf = { start = "change-preview-window(wrap-word)" } },
    fzf_opts = {
      ["--ansi"] = true,
      ["--preview-wrap-sign"] = " ",
      ["--delimiter"] = "\t",
      ["--with-nth"] = "1,2,5,6",
    },
    actions = {
      ["enter"] = function(selected)
        local num, _, base = plain(selected):match("^(%d+)\t([^\t]*)\t([^\t]*)")
        if num and base then require("config.review_mode").start(num, { base = base }) end
      end,
      ["ctrl-b"] = {
        fn = function(selected)
          local num = plain(selected):match("^(%d+)")
          if num then vim.fn.jobstart({ "gh", "pr", "view", num, "--web" }, { detach = true }) end
        end,
        noclose = true,
      },
    },
  })
end

return M
