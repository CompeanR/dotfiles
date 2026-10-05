local M = {}

local COLORS = {
  PrTitle = { fg = "#e9b143", bold = true },
  PrYellow = { fg = "#e9b143" },
  PrGreen = { fg = "#b0b846" },
  PrRed = { fg = "#f2594b" },
  PrPurple = { fg = "#d3869b" },
  PrAqua = { fg = "#8bba7f" },
  PrBlue = { fg = "#80aa9e" },
  PrOrange = { fg = "#f28534" },
  PrOrangeBold = { fg = "#f28534", bold = true },
  PrSoft = { fg = "#a89984" },
  PrDim = { fg = "#928374" },
  PrMuted = { fg = "#7c6f64" },
  PrFaint = { fg = "#504945" },
  PrCode = { fg = "#a9b665", bg = "#282828" },
  PrBold = { bold = true },
  PrGateBlocked = { fg = "#f28534", bg = "#3c2a1e" },
  PrGateWait = { fg = "#e9b143", bg = "#3a3420" },
  PrGateReady = { fg = "#b0b846", bg = "#34381b" },
  PrBoxWait = { bg = "#3a3420" },
  PrBoxReady = { bg = "#34381b" },
  PrBoxBlocked = { bg = "#3c2a1e" },
  PrGroupReady = { fg = "#b0b846", bold = true },
  PrGroupWaiting = { fg = "#e9b143", bold = true },
  PrGroupBlocked = { fg = "#f2594b", bold = true },
  PrGroupDraft = { fg = "#d3869b", bold = true },
  PrPending = { fg = "#665c54" },
  PrChip = { fg = "#282828", bg = "#f28534", bold = true },
  PrKey = { fg = "#282828", bg = "#e9b143", bold = true },
}

local function setup_hl()
  for name, spec in pairs(COLORS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

local LIST_FIELDS =
  "number,title,body,author,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,url,isDraft,state,statusCheckRollup,mergeable,reviewDecision,updatedAt,files"

-- Text helpers. A line is a list of { text, hl } segments, rendered either into
-- a buffer (extmarks) or into ANSI for fzf.

local function width(text) return vim.fn.strdisplaywidth(text) end

local function fit(text, w, align_right)
  if w <= 0 then return "" end
  if width(text) > w then
    local chars = vim.fn.strchars(text)
    while chars > 0 and width(text) > w - 1 do
      chars = chars - 1
      text = vim.fn.strcharpart(text, 0, chars)
    end
    text = text .. "…"
  end
  local pad = string.rep(" ", w - width(text))
  return align_right and pad .. text or text .. pad
end

local function fit_line(segs, w)
  local out, used = {}, 0
  for _, seg in ipairs(segs) do
    local sw = width(seg[1])
    if used + sw > w then
      out[#out + 1] = { fit(seg[1], w - used), seg[2] }
      return out
    end
    out[#out + 1] = seg
    used = used + sw
  end
  out[#out + 1] = { string.rep(" ", w - used) }
  return out
end

local ns = vim.api.nvim_create_namespace("review_pr")

local function to_buf(buf, lines, line_hls)
  local texts = {}
  for i, segs in ipairs(lines) do
    local parts = {}
    for _, seg in ipairs(segs) do parts[#parts + 1] = seg[1] end
    texts[i] = table.concat(parts)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, segs in ipairs(lines) do
    local col = 0
    for _, seg in ipairs(segs) do
      if seg[2] then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = col + #seg[1], hl_group = seg[2] })
      end
      col = col + #seg[1]
    end
    if line_hls and line_hls[i] then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = line_hls[i] })
    end
  end
end

local function footer(keys)
  local chunks = { { " " } }
  for i, key in ipairs(keys) do
    if i > 1 then chunks[#chunks + 1] = { " · ", "PrOrange" } end
    chunks[#chunks + 1] = { key[1], "PrOrangeBold" }
    chunks[#chunks + 1] = { " " .. key[2], "PrOrange" }
  end
  chunks[#chunks + 1] = { " " }
  return chunks
end

-- Time

local function parse_time(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y or tonumber(y) < 2000 then return nil end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  return t + os.difftime(os.time(), os.time(os.date("!*t")))
end

local function ago(iso)
  local t = parse_time(iso)
  if not t then return "" end
  local secs = math.max(0, os.time() - t)
  if secs < 60 then return "now" end
  if secs < 3600 then return math.floor(secs / 60) .. "m" end
  if secs < 86400 then return math.floor(secs / 3600) .. "h" end
  if secs < 86400 * 30 then return math.floor(secs / 86400) .. "d" end
  if secs < 86400 * 365 then return math.floor(secs / (86400 * 30)) .. "mo" end
  return math.floor(secs / (86400 * 365)) .. "y"
end

local function updated_ago(iso)
  local age = ago(iso)
  return age == "now" and "just now" or age .. " ago"
end

local function duration(secs)
  secs = math.max(0, math.floor(secs))
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then return string.format("%dm %02ds", secs / 60, secs % 60) end
  return string.format("%dh %02dm", secs / 3600, (secs % 3600) / 60)
end

-- Checks and merge gate

local ICON = { pass = "✓", fail = "✗", pending = "●", cancelled = "–" }
local ICON_HL = { pass = "PrGreen", fail = "PrRed", pending = "PrYellow", cancelled = "PrMuted" }

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

local function check_detail(check, state)
  local started, completed = parse_time(check.startedAt), parse_time(check.completedAt)
  if state == "pending" then
    if check.status == "IN_PROGRESS" and started then
      return "running " .. (ago(check.startedAt) == "now" and "<1m" or ago(check.startedAt))
    end
    return "queued"
  end
  if started and completed then return duration(completed - started) end
  return ""
end

local function checks_of(pr)
  if pr._checks then return pr._checks end
  local rank = { fail = 4, pending = 3, pass = 2, cancelled = 1 }
  local list, by_name = {}, {}
  for _, check in ipairs(pr.statusCheckRollup or {}) do
    local name = check.name or check.context or "check"
    local state = check_state(check)
    local item = {
      name = name,
      state = state,
      detail = check_detail(check, state),
      url = check.detailsUrl or check.targetUrl,
    }
    local prev = by_name[name]
    if not prev then
      by_name[name] = item
      list[#list + 1] = item
    elseif rank[state] > rank[prev.state] then
      prev.state, prev.detail = item.state, item.detail
      prev.url = item.url
    end
  end
  pr._checks = list
  return list
end

local function tally(checks)
  local counts = { pass = 0, fail = 0, pending = 0, cancelled = 0, total = #checks }
  for _, check in ipairs(checks) do counts[check.state] = counts[check.state] + 1 end
  return counts
end

local function first_named(checks, state)
  for _, check in ipairs(checks) do
    if check.state == state then return check.name end
  end
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function failed_label(checks, count)
  return count == 1 and first_named(checks, "fail") or count .. " checks"
end

local function ci_summary(checks)
  local c = tally(checks)
  if c.total == 0 then return { { "–", "PrMuted" }, { " no checks" } } end
  if c.fail > 0 then return { { "✗", "PrRed" }, { string.format(" CI %d failed, %d passed", c.fail, c.pass) } } end
  if c.pending > 0 then
    return { { "●", "PrYellow" }, { string.format(" CI %d running, %d passed", c.pending, c.pass) } }
  end
  return { { "✓", "PrGreen" }, { string.format(" CI %d/%d passed", c.pass, c.total) } }
end

local function refs_text(behind)
  local refs, count = behind.refs, behind.count
  if #refs == 0 then return "" end
  local shown = count > 3 and 2 or 3
  local names = vim.list_slice(refs, 1, shown)
  if count > #names then names[#names + 1] = "+" .. (count - #names) end
  return table.concat(names, ", ")
end

local function behind_visible(pr) return pr._behind ~= nil and pr.mergeable ~= "CONFLICTING" end

local function behind_segs(pr)
  local refs = refs_text(pr._behind)
  return {
    { "↓" .. pr._behind.count, "PrYellow" },
    { " behind " .. pr.baseRefName .. (refs ~= "" and " (" .. refs .. ")" or "") },
  }
end

local function ran_before(pr)
  local oldest = pr._behind.refs[#pr._behind.refs]
  return oldest and ("ran on " .. pr.baseRefName .. " before " .. oldest) or ("ran before " .. pr.baseRefName .. " moved")
end

local function ci_estimate(pr)
  local longest
  for _, check in ipairs(pr.statusCheckRollup or {}) do
    local started, completed = parse_time(check.startedAt), parse_time(check.completedAt)
    if started and completed and (not longest or completed - started > longest) then longest = completed - started end
  end
  return longest and "~" .. math.max(1, math.ceil(longest / 60)) .. "m" or nil
end

local function pr_status(pr)
  local checks = checks_of(pr)
  local c = tally(checks)
  local failed = c.fail > 0 and failed_label(checks, c.fail) or nil
  local waiting = plural(c.pending, "check")
  local function blocked(reason, text, group)
    return { gate = "blocked", group = group or "blocked", reason = reason, text = text or "blocked: " .. reason .. "." }
  end

  if pr.state and pr.state ~= "OPEN" then return blocked("the PR is " .. pr.state:lower()) end
  if pr.isDraft then
    local text = "blocked: draft. Mark it ready, then merging squashes right away."
    if failed then
      text = "blocked: draft, and " .. failed .. " failed."
    elseif c.pending > 0 then
      text = "blocked: draft. Once ready, merging waits for " .. waiting .. ", then merges."
    end
    return blocked("it is a draft, mark it ready first", text, "draft")
  end
  if pr.mergeable == "CONFLICTING" then return blocked("conflicts with " .. pr.baseRefName) end
  if pr.reviewDecision == "CHANGES_REQUESTED" then return blocked("changes requested") end
  if pr.reviewDecision == "REVIEW_REQUIRED" then return blocked("review required") end
  if failed then return blocked(failed .. " failed") end
  if c.pending > 0 then return { gate = "wait", group = "waiting", text = "waits for " .. waiting .. ", then squash-merges." } end
  if pr.mergeable == "UNKNOWN" then
    return { gate = "wait", group = "waiting", text = "waits for GitHub to compute conflicts, then squash-merges." }
  end
  if pr._behind then
    local estimate = ci_estimate(pr)
    return {
      gate = "wait",
      group = "ready",
      text = "updates the branch with " .. pr.baseRefName .. ", re-runs CI" .. (estimate and " (" .. estimate .. ")" or "") .. ", then merges.",
    }
  end
  return { gate = "ready", group = "ready", text = "squash-merges right away." }
end

local GATE_HL = { blocked = "PrGateBlocked", wait = "PrGateWait", ready = "PrGateReady" }

-- Markdown body

local function body_lines(pr)
  local body = type(pr.body) == "string" and pr.body or ""
  body = body:gsub("\r", ""):gsub("<!%-%-.-%-%->", "")
  local lines = vim.split(body, "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do table.remove(lines) end
  while #lines > 0 and vim.trim(lines[1]) == "" do table.remove(lines, 1) end
  return lines
end

local function fenced(lines)
  local flags, open = {}, false
  for i, line in ipairs(lines) do
    local mark = vim.trim(line):match("^```") ~= nil
    flags[i] = open or mark
    if mark then open = not open end
  end
  return flags
end

-- First paragraph or list item, skipping lead-ins that end in ":" and code blocks.

-- GitHub

local CACHE_TTL = 20
local cache = {}
local describe_win

local function now() return vim.uv.hrtime() / 1e9 end

local function system(args, dir, on_done, env)
  vim.system(args, { cwd = dir, text = true, env = env }, function(result)
    vim.schedule(function() on_done(result.code == 0, result.stdout or "", result.stderr or "", result.code) end)
  end)
end

local function decode_json(text)
  local ok, decoded = pcall(vim.json.decode, text)
  return ok and type(decoded) == "table" and decoded or nil
end

local function view_pr(number, dir, on_done)
  local args = { "gh", "pr", "view" }
  if number then args[#args + 1] = tostring(number) end
  vim.list_extend(args, { "--json", LIST_FIELDS })
  system(args, dir, function(ok, out) on_done(ok and decode_json(out) or nil) end)
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

-- Behind detection and conflict fixes

local function parse_worktrees(text)
  local map, main, path = {}, nil, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local tree = line:match("^worktree (.+)")
    if tree then
      path = tree
      main = main or tree
    end
    local branch = line:match("^branch refs/heads/(.+)")
    if branch then map[branch] = path end
  end
  return map, main
end

local function worktrees(dir)
  return parse_worktrees(table.concat(vim.fn.systemlist({ "git", "-C", dir, "worktree", "list", "--porcelain" }), "\n"))
end

local function fix_command(trees, main, branch, base)
  local path = trees[branch]
  local origin = vim.fn.shellescape("origin/" .. base)
  local quoted = vim.fn.shellescape(branch)
  if path then
    return string.format("cd %s && git fetch origin && git merge %s && git push", vim.fn.shellescape(path), origin)
  end
  local new_path = vim.fn.shellescape(main .. "-wt/" .. branch:match("[^/]+$"))
  return string.format("git fetch origin && git worktree add %s %s && cd %s && git merge %s && git push", new_path, quoted, new_path, origin)
end

local function base_shas(dir, prs, on_done)
  local shas, pending, bases = {}, 0, {}
  for _, pr in ipairs(prs) do bases[pr.baseRefName] = true end
  for base in pairs(bases) do
    pending = pending + 1
    system({ "gh", "api", "repos/{owner}/{repo}/branches/" .. base, "--jq", ".commit.sha" }, dir, function(ok, out)
      shas[base] = ok and vim.trim(out) or nil
      pending = pending - 1
      if pending == 0 then on_done(shas) end
    end)
  end
  if pending == 0 then on_done(shas) end
end

local compare_cache = {}

local function behind_of(dir, head, base_sha, on_done)
  local key = head .. "..." .. base_sha
  if compare_cache[key] then return on_done(compare_cache[key]) end
  local jq = '{count: .ahead_by, subjects: [.commits[].commit.message | split("\n")[0]] | reverse}'
  system({ "gh", "api", "repos/{owner}/{repo}/compare/" .. key, "--jq", jq }, dir, function(ok, out)
    local result = ok and decode_json(out) or nil
    if result then compare_cache[key] = result end
    on_done(result)
  end)
end

local function refs_of(subjects)
  local refs = {}
  for _, subject in ipairs(subjects or {}) do
    local number = subject:match("%(#(%d+)%)%s*$") or subject:match("^Merge pull request #(%d+)")
    if number then refs[#refs + 1] = "#" .. number end
  end
  return refs
end

-- Sets pr._behind (commits the base has that the head lacks) and pr._fix (the
-- command that merges the base into a conflicting PR in its worktree).
local function annotate(dir, prs, on_done)
  base_shas(dir, prs, function(shas)
    local open = vim.tbl_filter(function(pr) return (pr.state or "OPEN") == "OPEN" and shas[pr.baseRefName] ~= nil end, prs)
    local pending = #open

    local function finish_all()
      local trees, main
      for _, pr in ipairs(prs) do
        pr._fix = nil
        if pr.mergeable == "CONFLICTING" then
          if not trees then trees, main = worktrees(dir) end
          pr._fix = fix_command(trees, main, pr.headRefName, pr.baseRefName)
        end
      end
      on_done(prs)
    end

    for _, pr in ipairs(prs) do pr._behind = nil end
    if pending == 0 then return finish_all() end
    for _, pr in ipairs(open) do
      behind_of(dir, pr.headRefOid, shas[pr.baseRefName], function(result)
        if result and type(result.count) == "number" and result.count > 0 then
          pr._behind = { count = result.count, refs = refs_of(result.subjects) }
        end
        pending = pending - 1
        if pending == 0 then finish_all() end
      end)
    end
  end)
end

-- Shared PR header pieces

local function title_line(pr)
  return { { string.format("#%d %s", pr.number, pr.title), "PrTitle" } }
end

local function branch_segs(pr)
  return {
    { pr.author.login, "PrBlue" }, { "  " },
    { pr.baseRefName, "PrAqua" }, { " ← ", "PrDim" }, { pr.headRefName, "PrAqua" },
  }
end

local function diff_segs(pr)
  return { { "+" .. pr.additions, "PrGreen" }, { " " }, { "-" .. pr.deletions, "PrRed" } }
end

local function state_segs(pr)
  if pr.state == "MERGED" then return { { "●", "PrPurple" }, { " merged" } } end
  if pr.state == "CLOSED" then return { { "✗", "PrRed" }, { " closed" } } end
  if pr.isDraft then return { { "◌", "PrPurple" }, { " draft " }, { "✗", "PrRed" } } end
  return { { "●", "PrGreen" }, { " open " }, { "✓", "PrGreen" } }
end

local function conflict_segs(pr)
  if pr.mergeable == "MERGEABLE" then return { { "✓", "PrGreen" }, { " no conflicts" } } end
  if pr.mergeable == "CONFLICTING" then return { { "✗", "PrRed" }, { " conflicts with " .. pr.baseRefName } } end
  return { { "○", "PrDim" }, { " conflicts not computed yet" } }
end

local function concat(...)
  local out = {}
  for _, segs in ipairs({ ... }) do vim.list_extend(out, segs) end
  return out
end

local function copy_fix(fix)
  if not fix then return vim.notify("Nothing to fix on this PR", vim.log.levels.INFO) end
  vim.fn.setreg("+", fix)
  vim.notify("Copied: " .. fix)
end

-- <leader>gp: detail float with a pinned header

local MAX_CHECK_ROWS = 10

local function float_height() return math.floor(vim.o.lines * 0.9) end

local function detail_header(pr, w)
  local lines = {
    fit_line(title_line(pr), w),
    fit_line(concat(branch_segs(pr), { { "  · ", "PrDim" } }, diff_segs(pr), {
      { string.format("  %s · updated %s", plural(pr.changedFiles, "file"), updated_ago(pr.updatedAt)), "PrDim" },
    }), w),
    {},
  }

  local checks = checks_of(pr)
  local right = { { { "merge (squash, head-pinned)", "PrMuted" } }, state_segs(pr) }
  if pr.state == "OPEN" then right[#right + 1] = conflict_segs(pr) end
  right[#right + 1] = ci_summary(checks)
  if behind_visible(pr) then right[#right + 1] = behind_segs(pr) end

  local fixed_rows = #lines + 2 + (pr._fix and 1 or 0)
  local rows = math.max(#right, math.floor(float_height() / 2) - fixed_rows)
  local limit = math.min(rows, MAX_CHECK_ROWS + 1)
  local shown = #checks + 1 > limit and limit - 2 or #checks
  local left = { { { "checks", "PrMuted" } } }
  if pr._behind then left[1][2] = { " · " .. ran_before(pr), "PrFaint" } end
  for i = 1, shown do
    local check = checks[i]
    left[#left + 1] = {
      { ICON[check.state], ICON_HL[check.state] }, { " " .. check.name .. " " }, { check.detail, "PrMuted" },
    }
  end
  if #checks > shown then
    left[#left + 1] = { { string.format("… +%d more", #checks - shown), "PrMuted" } }
  end
  if #checks == 0 then left[#left + 1] = { { "–", "PrMuted" }, { " no checks" } } end

  local col = math.floor((w - 2) / 2)
  for i = 1, math.max(#left, #right) do
    lines[#lines + 1] = concat(fit_line(left[i] or {}, col), { { "  " } }, fit_line(right[i] or {}, w - col - 2))
  end

  local status = pr_status(pr)
  lines[#lines + 1] = {}
  lines[#lines + 1] = fit_line({ { " alt-m", "PrBold" }, { "  " .. status.text } }, w)
  local gate_row = #lines
  if pr._fix then lines[#lines + 1] = fit_line({ { " fix  ", "PrMuted" }, { pr._fix, "PrCode" } }, w) end
  return lines, { [gate_row] = GATE_HL[status.gate] }
end

local function detail_layout(view, header_height)
  local w = math.floor(vim.o.columns * 0.76)
  local total = float_height()
  local row = math.floor((vim.o.lines - total) / 2)
  local col = math.floor((vim.o.columns - w - 2) / 2)
  header_height = math.min(header_height, math.max(1, total - 6))
  vim.api.nvim_win_set_config(view.header, {
    relative = "editor", row = row, col = col, width = w, height = header_height,
  })
  vim.api.nvim_win_set_config(view.body, {
    relative = "editor", row = row + header_height + 2, col = col, width = w,
    height = math.max(3, total - header_height - 3),
  })
end

local DETAIL_KEYS = { { "q", "close" }, { "^b", "browser" }, { "alt-m", "merge (prm)" }, { "]]", "next section" } }

local function detail_open()
  local w = math.floor(vim.o.columns * 0.76)
  local header_buf = vim.api.nvim_create_buf(false, true)
  local body_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[header_buf].bufhidden = "wipe"
  vim.bo[body_buf].bufhidden = "wipe"
  vim.bo[body_buf].filetype = "markdown"
  vim.bo[body_buf].modifiable = false

  local base = { relative = "editor", row = 0, col = 0, width = w, height = 1, style = "minimal" }
  local header = vim.api.nvim_open_win(header_buf, false, vim.tbl_extend("force", base, {
    focusable = false,
    border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title = { { " PR ", "PrOrangeBold" } },
    title_pos = "center",
  }))
  local body = vim.api.nvim_open_win(body_buf, true, vim.tbl_extend("force", base, {
    border = { "", "", "", "│", "╯", "─", "╰", "│" },
    footer = footer(DETAIL_KEYS),
    footer_pos = "center",
  }))
  vim.wo[body].wrap = true
  vim.wo[body].linebreak = true
  vim.wo[header].wrap = false

  local view = { header = header, body = body, header_buf = header_buf, body_buf = body_buf, width = w }
  to_buf(header_buf, { { { "Loading PR…", "PrMuted" } } })
  detail_layout(view, 1)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(body),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(header) then vim.api.nvim_win_close(header, true) end
    end,
  })
  return view
end

local function detail_render(view, pr)
  if not vim.api.nvim_win_is_valid(view.body) then return end
  local lines, line_hls = detail_header(pr, view.width)
  to_buf(view.header_buf, lines, line_hls)

  local body = {}
  for _, line in ipairs(body_lines(pr)) do body[#body + 1] = { { line } } end
  if #body == 0 then body = { { { "_(no description)_" } } } end
  local cursor = vim.api.nvim_win_get_cursor(view.body)
  to_buf(view.body_buf, body)
  pcall(vim.api.nvim_win_set_cursor, view.body, cursor)

  detail_layout(view, #lines)
  vim.api.nvim_win_set_config(view.header, {
    title = { { string.format(" PR #%d ", pr.number), "PrOrangeBold" } },
    title_pos = "center",
  })
  local keys = vim.deepcopy(DETAIL_KEYS)
  if pr._fix then table.insert(keys, 4, { "alt-y", "copy fix" }) end
  vim.api.nvim_win_set_config(view.body, { footer = footer(keys), footer_pos = "center" })
end

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

  setup_hl()
  local key = dir .. ":" .. sha
  local entry = cache[key]
  local view = detail_open()
  describe_win = view.body
  if entry then detail_render(view, entry.pr) end

  local buf = view.body_buf
  local function close()
    if vim.api.nvim_win_is_valid(view.body) then vim.api.nvim_win_close(view.body, true) end
    describe_win = nil
  end
  local function refresh(pr)
    annotate(dir, { pr }, function()
      cache[key] = { pr = pr, at = now() }
      detail_render(view, pr)
    end)
  end
  local function map(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
  map("q", close)
  map("<Esc>", close)
  local function jump_heading(step)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local skip = fenced(lines)
    local from = vim.api.nvim_win_get_cursor(view.body)[1] + step
    for row = from, step > 0 and #lines or 1, step do
      if not skip[row] and lines[row]:match("^#+%s") then
        return vim.api.nvim_win_set_cursor(view.body, { row, 0 })
      end
    end
  end
  map("]]", function() jump_heading(1) end)
  map("[[", function() jump_heading(-1) end)
  map("<M-y>", function() copy_fix(cache[key] and cache[key].pr._fix) end)
  map("<C-b>", function()
    local current = cache[key]
    if not current then return end
    vim.fn.jobstart({ "gh", "pr", "view", tostring(current.pr.number), "--web" }, { cwd = dir, detach = true })
  end)

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

local history_path = vim.fn.stdpath("state") .. "/review_pr_history.json"

local function read_history()
  local file = io.open(history_path, "r")
  if not file then return {} end
  local data = decode_json(file:read("*a"))
  file:close()
  return type(data) == "table" and data or {}
end

local function entries_of(history, dir)
  if type(history[dir]) ~= "table" then return {} end
  return vim.tbl_filter(function(entry) return type(entry) == "table" and type(entry.number) == "number" end, history[dir])
end

local function remember(dir, pr)
  local history = read_history()
  local seen = vim.tbl_filter(function(entry) return entry.number ~= pr.number end, entries_of(history, dir))
  table.insert(seen, 1, { number = pr.number, base = pr.baseRefName, title = pr.title })
  history[dir] = vim.list_slice(seen, 1, 5)
  local file = io.open(history_path, "w")
  if file then
    file:write(vim.json.encode(history))
    file:close()
  end
end

function M.review(dir, pr)
  remember(dir, pr)
  require("config.review_mode").start(tostring(pr.number), { base = pr.baseRefName })
end

-- Reviews the most recent PR other than the one under review now.
function M.review_last()
  local dir = vim.fs.root(0, ".git") or vim.uv.cwd()
  local current = require("config.review_mode").pr()
  local target = vim.iter(entries_of(read_history(), dir)):find(function(entry) return entry.number ~= current end)
  if not target then return vim.notify("No other reviewed PR in this repo", vim.log.levels.INFO) end
  M.review(dir, { number = target.number, baseRefName = target.base, title = target.title })
end

return M
