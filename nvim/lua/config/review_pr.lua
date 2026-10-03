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
  PrGroupReady = { fg = "#b0b846", bold = true },
  PrGroupWaiting = { fg = "#e9b143", bold = true },
  PrGroupBlocked = { fg = "#f2594b", bold = true },
  PrGroupDraft = { fg = "#d3869b", bold = true },
}

local function setup_hl()
  for name, spec in pairs(COLORS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

local HEADING_ICONS = { "① ", "② ", "③ ", "④ ", "⑤ ", "⑥ " }
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

local function wrap(text, w, max_lines)
  local lines, current = {}, ""
  for word in text:gmatch("%S+") do
    if current == "" then
      current = word
    elseif width(current) + 1 + width(word) <= w then
      current = current .. " " .. word
    else
      lines[#lines + 1] = current
      current = word
    end
  end
  if current ~= "" then lines[#lines + 1] = current end
  if max_lines and #lines > max_lines then
    lines = vim.list_slice(lines, 1, max_lines)
    lines[max_lines] = fit(lines[max_lines] .. " …", w):gsub("%s+$", "")
  end
  return lines
end

local function to_ansi(segs)
  local utils = require("fzf-lua.utils")
  local parts = {}
  for _, seg in ipairs(segs) do
    parts[#parts + 1] = seg[2] and (utils.ansi_from_hl(seg[2], seg[1])) or seg[1]
  end
  return table.concat(parts)
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
    local item = { name = name, state = state, detail = check_detail(check, state) }
    local prev = by_name[name]
    if not prev then
      by_name[name] = item
      list[#list + 1] = item
    elseif rank[state] > rank[prev.state] then
      prev.state, prev.detail = item.state, item.detail
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

local function ci_short(checks)
  local c = tally(checks)
  if c.total == 0 then return { { "–", "PrMuted" }, { " no checks" } } end
  local base = string.format(" CI %d/%d", c.pass, c.total)
  if c.fail > 0 then
    return { { "✗", "PrRed" }, { base .. ", " .. failed_label(checks, c.fail) .. " failed" } }
  end
  if c.pending > 0 then
    local what = c.pending == 1 and first_named(checks, "pending") or tostring(c.pending)
    return { { "●", "PrYellow" }, { base .. ", " .. what .. " running" } }
  end
  return { { "✓", "PrGreen" }, { base } }
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
  if pr._stale then
    return {
      gate = "wait",
      group = "waiting",
      text = "CI ran before " .. pr.baseRefName .. " moved. Merging offers to update the branch first.",
    }
  end
  return { gate = "ready", group = "ready", text = "squash-merges right away." }
end

local GATE_HL = { blocked = "PrGateBlocked", wait = "PrGateWait", ready = "PrGateReady" }
local GATE_ICON = {
  blocked = { "✗", "PrOrange" },
  wait = { "●", "PrYellow" },
  ready = { "✓", "PrGreen" },
}

local function review_status(pr)
  local decision = pr.reviewDecision
  if decision == "APPROVED" then return { { "✓", "PrGreen" }, { " approved" } } end
  if decision == "CHANGES_REQUESTED" then return { { "✗", "PrRed" }, { " changes requested" } } end
  if decision == "REVIEW_REQUIRED" then return { { "○", "PrDim" }, { " review pending" } } end
  return { { "–", "PrMuted" }, { " no review yet" } }
end

-- Markdown body

local function body_lines(pr)
  local body = type(pr.body) == "string" and pr.body or ""
  body = body:gsub("\r", ""):gsub("<!%-%-.-%-%->", "")
  local lines = vim.split(body, "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do table.remove(lines) end
  while #lines > 0 and vim.trim(lines[1]) == "" do table.remove(lines, 1) end
  return lines
end

local function is_list_item(line) return line:match("^%s*[-*+]%s") or line:match("^%s*%d+[.)]%s") end

local function plain_md(text)
  return (text:gsub("`", ""):gsub("%*%*", ""):gsub("%[([^%]]*)%]%b()", "%1"))
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
local function summary_of(lines)
  local block, skip = {}, fenced(lines)
  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if not skip[i] then
      local blank, heading, item = trimmed == "", trimmed:match("^#"), is_list_item(line)
      if #block > 0 and (blank or heading or item) then
        if not block[#block]:match(":$") then break end
        block = {}
      end
      if not blank and not heading then
        block[#block + 1] = item and trimmed:gsub("^[-*+%d.)]+%s+", ""):gsub("^%[.%]%s*", "") or trimmed
      end
    end
  end
  return plain_md(table.concat(block, " "))
end

local function outline_of(lines, summary)
  local sections, skip = {}, fenced(lines)
  for i, line in ipairs(lines) do
    local hashes, title = line:match("^(#+)%s+(.*)")
    if hashes and not skip[i] then
      sections[#sections + 1] = { level = math.min(#hashes, 6), title = title, items = 0, lines = 0 }
    elseif #sections > 0 then
      local section = sections[#sections]
      if vim.trim(line) ~= "" then section.lines = section.lines + 1 end
      if not skip[i] and is_list_item(line) then
        section.items = section.items + 1
      elseif not skip[i] and not section.text and vim.trim(line) ~= "" then
        section.text = plain_md(vim.trim(line))
      end
    end
  end
  for _, section in ipairs(sections) do
    if section.items > 0 then
      section.note = plural(section.items, "item")
    elseif section.text and summary:sub(1, #section.text) == section.text then
      section.note = plural(section.lines, "line")
    elseif section.text then
      local sentence = section.text:match("^(.-)[.!?]%s") or section.text:match("^(.-)[.!?]?$") or section.text
      section.note = sentence:sub(1, 1):lower() .. sentence:sub(2)
    end
  end
  return sections
end

local function md_segments(line, in_fence)
  if in_fence then return { { line, "PrCode" } } end
  local hashes, title = line:match("^(#+)%s+(.*)")
  if hashes then return { { HEADING_ICONS[math.min(#hashes, 6)] .. title, "PrOrangeBold" } } end
  local segs, code = {}, false
  for part in (line .. "`"):gmatch("([^`]*)`") do
    if part ~= "" then segs[#segs + 1] = { part, code and "PrCode" or nil } end
    code = not code
  end
  return segs
end

-- GitHub

local CACHE_TTL = 20
local cache = {}
local list_cache = {}
local describe_win

local function now() return vim.uv.hrtime() / 1e9 end

local function system(args, dir, on_done)
  vim.system(args, { cwd = dir, text = true }, function(result)
    vim.schedule(function() on_done(result.code == 0, result.stdout or "", result.stderr or "") end)
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

-- Merge fallout: stale CI, conflict fixes, stacked PRs

local stacked_fixes = {}

local function worktrees(dir)
  local map, path = {}, nil
  for _, line in ipairs(vim.fn.systemlist({ "git", "-C", dir, "worktree", "list", "--porcelain" })) do
    path = line:match("^worktree (.+)") or path
    local branch = line:match("^branch refs/heads/(.+)")
    if branch then map[branch] = path end
  end
  return map
end

local function fix_command(trees, branch, base, onto)
  local path = trees[branch]
  local origin = vim.fn.shellescape("origin/" .. base)
  local go = path and ("cd " .. vim.fn.shellescape(path) .. " && git fetch")
    or ("git fetch && git switch " .. vim.fn.shellescape(branch))
  local rebase = onto and string.format("git rebase --onto %s %s", origin, onto:sub(1, 12))
    or ("git rebase " .. origin)
  return go .. " && " .. rebase .. " && git push --force-with-lease"
end

local function latest_check_start(pr)
  local latest
  for _, check in ipairs(pr.statusCheckRollup or {}) do
    local started = parse_time(check.startedAt)
    if started and (not latest or started > latest) then latest = started end
  end
  return latest
end

local function base_times(dir, prs, on_done)
  local times, pending = {}, 0
  local bases = {}
  for _, pr in ipairs(prs) do bases[pr.baseRefName] = true end
  for base in pairs(bases) do
    pending = pending + 1
    system({ "gh", "api", "repos/{owner}/{repo}/branches/" .. base, "--jq", ".commit.commit.committer.date" }, dir,
      function(ok, out)
        times[base] = ok and parse_time(vim.trim(out)) or nil
        pending = pending - 1
        if pending == 0 then on_done(times) end
      end)
  end
  if pending == 0 then on_done(times) end
end

-- Sets pr._stale (CI ran before the base branch last moved) and pr._fix (the
-- command that rebases a conflicting or formerly stacked PR in its worktree).
local function annotate(dir, prs, on_done)
  base_times(dir, prs, function(times)
    local trees
    for _, pr in ipairs(prs) do
      local moved, started = times[pr.baseRefName], latest_check_start(pr)
      pr._stale = tally(checks_of(pr)).pending == 0 and moved ~= nil and started ~= nil and started < moved
      local stacked = (stacked_fixes[dir] or {})[pr.number]
      pr._fix = stacked and stacked.sha == pr.headRefOid and stacked.cmd or nil
      if not pr._fix and pr.mergeable == "CONFLICTING" then
        trees = trees or worktrees(dir)
        pr._fix = fix_command(trees, pr.headRefName, pr.baseRefName)
      end
    end
    on_done(prs)
  end)
end

local function stacked_children(dir, pr, on_done)
  system({ "gh", "pr", "list", "--base", pr.headRefName, "--json", "number,headRefName,headRefOid" }, dir,
    function(ok, out) on_done(ok and decode_json(out) or {}) end)
end

local REPORT_POLLS = 10

local function conflicting_numbers(prs)
  local set = {}
  for _, pr in ipairs(prs or {}) do
    if pr.mergeable == "CONFLICTING" then set[pr.number] = true end
  end
  return set
end

-- After a merge, re-checks the open PRs on the same base and sends one notice.
-- GitHub recomputes mergeability lazily, so it polls while any PR is UNKNOWN.
-- Only reports conflicts the merge introduced and CI that was current until it.
local function report_fallout(dir, merged, children, before, base_before, polls)
  polls = polls or 0
  system({ "gh", "pr", "list", "--base", merged.baseRefName, "--limit", "50", "--json", LIST_FIELDS }, dir,
    function(ok, out)
      local prs = ok and decode_json(out) or nil
      if not prs then
        return vim.notify(string.format("After #%d: could not re-check open PRs", merged.number), vim.log.levels.WARN)
      end
      local unknown = vim.iter(prs):any(function(pr) return pr.mergeable == "UNKNOWN" end)
      if unknown and polls < REPORT_POLLS then
        return vim.defer_fn(function()
          report_fallout(dir, merged, children, before, base_before, polls + 1)
        end, 3000)
      end
      annotate(dir, prs, function()
        local lines, stale, warn = {}, {}, false
        local stacked = {}
        for _, child in ipairs(children) do
          stacked[child.number] = true
          warn = true
          lines[#lines + 1] = string.format("↳ #%d was stacked on #%d: %s", child.number, merged.number,
            stacked_fixes[dir][child.number].cmd)
        end
        for _, pr in ipairs(prs) do
          if not stacked[pr.number] then
            if pr.mergeable == "CONFLICTING" and not before[pr.number] then
              warn = true
              lines[#lines + 1] = string.format("✗ #%d conflicts with %s: %s", pr.number, pr.baseRefName, pr._fix)
            elseif pr.mergeable == "UNKNOWN" then
              lines[#lines + 1] = string.format("○ #%d: GitHub has not computed conflicts yet", pr.number)
            end
            local started = latest_check_start(pr)
            if pr._stale and pr.mergeable ~= "CONFLICTING" and started and base_before and started > base_before then
              stale[#stale + 1] = "#" .. pr.number
            end
          end
        end
        if #stale > 0 then lines[#lines + 1] = "● CI ran before this merge: " .. table.concat(stale, ", ") end
        if #lines == 0 then
          return vim.notify(string.format("After #%d: other PRs OK", merged.number))
        end
        vim.notify(string.format("After #%d:\n%s", merged.number, table.concat(lines, "\n")),
          warn and vim.log.levels.WARN or vim.log.levels.INFO)
      end)
    end)
end

local function snapshot(dir, pr, on_done)
  system({ "gh", "pr", "list", "--base", pr.baseRefName, "--limit", "50", "--json", "number,mergeable" }, dir,
    function(ok, out)
      local before = conflicting_numbers(ok and decode_json(out) or nil)
      base_times(dir, { pr }, function(times) on_done(before, times[pr.baseRefName]) end)
    end)
end

local SETTLE_POLLS = 24
local in_flight = {}

M.settle_ms = 5000

-- What must settle before the merge decision can be trusted, or nil.
local function unsettled(pr, counts, opts)
  if pr.mergeable == "UNKNOWN" then return "GitHub has not computed conflicts yet" end
  if opts.updated then
    if pr.headRefOid == opts.from then return "the branch update has not landed yet" end
    if counts.total == 0 then return "CI has not started after the branch update" end
  end
  if opts.watched and counts.pending > 0 then return "checks are still running" end
end

-- opts.auto: already confirmed, opts.updated/opts.from: branch updated from that head,
-- opts.watched: already waited for CI once, opts.polls: settle retries so far.
local function attempt(dir, number, opts, finish, after)
  local function stop(message, level)
    vim.notify(message, level or vim.log.levels.WARN)
    finish()
  end
  local function refuse(reason) stop(string.format("Not merging #%d: %s", number, reason)) end
  local function guard(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        finish()
        error(err, 0)
      end
    end
  end
  local function again(next_opts)
    vim.defer_fn(guard(function() attempt(dir, number, next_opts, finish, after) end), M.settle_ms)
  end

  view_pr(number, dir, guard(function(pr)
    if not pr then return stop("Could not read PR #" .. number, vim.log.levels.ERROR) end
    annotate(dir, { pr }, guard(function()
      local status = pr_status(pr)
      if status.gate == "blocked" then
        local fix = pr.mergeable == "CONFLICTING" and pr._fix and (". Fix: " .. pr._fix) or ""
        return refuse(status.reason .. fix)
      end
      local counts = tally(checks_of(pr))

      local why = unsettled(pr, counts, opts)
      if why then
        local polls = (opts.polls or 0) + 1
        if polls == 1 then vim.notify(string.format("Waiting for GitHub to settle #%d: %s…", number, why)) end
        if polls > SETTLE_POLLS then return refuse(why) end
        return again(vim.tbl_extend("force", opts, { polls = polls }))
      end

      stacked_children(dir, pr, guard(function(children)
        local note = ""
        if #children > 0 then
          local numbers = vim.tbl_map(function(child) return "#" .. child.number end, children)
          note = string.format("\n\nStacked on this PR: %s. They will need a rebase --onto after the squash.",
            table.concat(numbers, ", "))
        end

        local function watch()
          vim.notify(string.format("Waiting for CI on #%d…", number))
          local job = vim.fn.jobstart({ "gh", "pr", "checks", tostring(number), "--watch", "--fail-fast" }, {
            cwd = dir,
            on_exit = function(_, code)
              vim.schedule(guard(function()
                if code ~= 0 then return stop(string.format("CI did not pass: not merging #%d", number)) end
                local next_opts = vim.tbl_extend("force", opts, { auto = true, watched = true, polls = 0 })
                attempt(dir, number, next_opts, finish, after)
              end))
            end,
          })
          if job <= 0 then stop(string.format("Could not watch CI on #%d", number), vim.log.levels.ERROR) end
        end

        if counts.pending > 0 then
          if opts.auto then return watch() end
          local choice = vim.fn.confirm(
            string.format("#%d: CI is still running.\nWait for it, then squash and merge if all checks pass?%s", number, note),
            "&Wait and merge\n&Cancel", 2
          )
          if choice == 1 then return watch() end
          return finish()
        end

        if pr._stale and not opts.force and not opts.updated then
          local choice = vim.fn.confirm(
            string.format("#%d: CI ran before %s moved.\nUpdate the branch, wait for CI, then merge?%s",
              number, pr.baseRefName, note),
            "&Update and merge\n&Merge anyway\n&Cancel", 3
          )
          if choice == 2 then return attempt(dir, number, { auto = true, force = true }, finish, after) end
          if choice ~= 1 then return finish() end
          return system({ "gh", "pr", "update-branch", tostring(number) }, dir, guard(function(ok, _, err)
            if not ok then
              return stop(string.format("Could not update #%d: %s\nFix by hand: %s", number, vim.trim(err),
                fix_command(worktrees(dir), pr.headRefName, pr.baseRefName)))
            end
            vim.notify(string.format("Updated #%d with %s. Waiting for CI…", number, pr.baseRefName))
            again({ auto = true, updated = true, from = pr.headRefOid })
          end))
        end

        if not opts.auto then
          local none = counts.total == 0 and "\n(no CI checks reported)" or ""
          local choice = vim.fn.confirm(
            string.format("Squash and merge #%d?\n%s%s%s", number, pr.title, none, note), "&Merge\n&Cancel", 2
          )
          if choice ~= 1 then return finish() end
        end

        snapshot(dir, pr, guard(function(before, base_before)
          system({ "gh", "pr", "merge", tostring(number), "--squash", "--match-head-commit", pr.headRefOid }, dir,
            guard(function(ok, _, err)
              if not ok then return stop("Merge failed: " .. vim.trim(err), vim.log.levels.ERROR) end
              list_cache[dir] = nil
              if #children > 0 then
                local trees = worktrees(dir)
                stacked_fixes[dir] = stacked_fixes[dir] or {}
                for _, child in ipairs(children) do
                  stacked_fixes[dir][child.number] = {
                    sha = child.headRefOid,
                    cmd = fix_command(trees, child.headRefName, pr.baseRefName, pr.headRefOid),
                  }
                end
              end
              vim.notify(string.format("Merged #%d (squash). Clean up its worktree and branch by hand.", number))
              finish()
              report_fallout(dir, pr, children, before, base_before)
              after()
            end))
        end))
      end))
    end))
  end))
end

-- Squash-merges only a fresh, open, non-draft, conflict-free PR whose checks all
-- passed, pinned to the head that was read. It can wait for running CI or offer to
-- update a branch whose CI ran before the base moved.
local function merge_pr(dir, number, opts, after)
  local key = dir .. "#" .. number
  if in_flight[key] then
    return vim.notify(string.format("Merge of #%d is already in progress", number), vim.log.levels.INFO)
  end
  in_flight[key] = true
  attempt(dir, number, opts or {}, function() in_flight[key] = nil end, after)
end
M.merge_pr = merge_pr

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

local function copy_fix(pr)
  local fix = pr and pr._fix
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
  if pr._stale then right[#right + 1] = { { "●", "PrYellow" }, { " CI ran before " .. pr.baseRefName .. " moved" } } end

  local fixed_rows = #lines + 2 + (pr._fix and 1 or 0)
  local rows = math.max(#right, math.floor(float_height() / 2) - fixed_rows)
  local limit = math.min(rows, MAX_CHECK_ROWS + 1)
  local shown = #checks + 1 > limit and limit - 2 or #checks
  local left = { { { "checks", "PrMuted" } } }
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
  lines[#lines + 1] = fit_line({ { " M", "PrBold" }, { "  " .. status.text } }, w)
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

local DETAIL_KEYS = { { "q", "close" }, { "^b", "browser" }, { "M", "merge when CI passes" }, { "]]", "next section" } }

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
  map("<M-y>", function() copy_fix(cache[key] and cache[key].pr) end)
  map("<C-b>", function()
    local current = cache[key]
    if not current then return end
    vim.fn.jobstart({ "gh", "pr", "view", tostring(current.pr.number), "--web" }, { cwd = dir, detach = true })
  end)
  map("M", function()
    local current = cache[key]
    if not current then return vim.notify("Still loading the PR", vim.log.levels.INFO) end
    merge_pr(dir, current.pr.number, {}, function()
      view_pr(current.pr.number, dir, function(pr)
        if pr then refresh(pr) end
      end)
    end)
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

-- <leader>gP: picker grouped by what you can do next

local GROUPS = {
  { key = "ready", label = "✓ ready to merge", hl = "PrGroupReady" },
  { key = "waiting", label = "● waiting on CI", hl = "PrGroupWaiting" },
  { key = "blocked", label = "✗ needs work", hl = "PrGroupBlocked" },
  { key = "draft", label = "◌ draft", hl = "PrGroupDraft" },
}

local function group_header(group, count, w)
  local label, tail = group.label .. " ", " " .. count
  local rule = math.max(1, w - width(label) - width(tail))
  return { { label, group.hl }, { string.rep("─", rule), "PrFaint" }, { tail, "PrMuted" } }
end

local function pick_row(pr, group, w)
  local branch_w = w >= 90 and 22 or 0
  local title_w = w - 4 - 2 - (branch_w > 0 and branch_w + 2 or 0) - 12 - 2 - 4 - 2
  local diff = "+" .. pr.additions .. " -" .. pr.deletions
  local first = {
    { fit(tostring(pr.number), 4), "PrYellow" }, { "  " },
    { fit(pr.title, title_w) }, { "  " },
  }
  if branch_w > 0 then vim.list_extend(first, { { fit(pr.headRefName, branch_w), "PrAqua" }, { "  " } }) end
  vim.list_extend(first, {
    { "+" .. pr.additions, "PrGreen" }, { " " }, { "-" .. pr.deletions, "PrRed" },
    { string.rep(" ", math.max(0, 12 - width(diff))) }, { "  " },
    { fit(ago(pr.updatedAt), 4, true), "PrSoft" },
  })

  local status = concat({ { "      " } }, ci_short(checks_of(pr)), { { "  " } }, review_status(pr))
  if pr.mergeable == "CONFLICTING" then
    status = concat(status, { { "  " }, { "✗", "PrRed" }, { " conflicts" } })
  elseif group == "ready" and pr.mergeable == "MERGEABLE" then
    status = concat(status, { { "  " }, { "✓", "PrGreen" }, { " mergeable" } })
  end
  if pr._stale then status = concat(status, { { "  " }, { "●", "PrYellow" }, { " stale CI" } }) end
  for i = 2, #status do
    if not status[i][2] then status[i] = { status[i][1], "PrDim" } end
  end
  return { first, fit_line(status, w) }
end

local MAX_FILE_ROWS = 8

local function pick_summary(pr, cols)
  local left_w = math.floor((cols - 3) * 0.6)
  local right_w = cols - 3 - left_w
  local body = body_lines(pr)

  local left = {}
  for _, text in ipairs(wrap(string.format("#%d %s", pr.number, pr.title), left_w)) do
    left[#left + 1] = { { text, "PrTitle" } }
  end
  left[#left + 1] = concat(branch_segs(pr), { { "  · " .. plural(pr.changedFiles, "file"), "PrDim" } })
  left[#left + 1] = {}
  left[#left + 1] = { { "summary", "PrMuted" } }
  local summary = summary_of(body)
  for _, text in ipairs(summary ~= "" and wrap(summary, left_w, 4) or { "(no description)" }) do
    left[#left + 1] = { { text } }
  end
  local outline = outline_of(body, summary)
  if #outline > 0 then
    left[#left + 1] = {}
    left[#left + 1] = { { "outline", "PrMuted" }, { " · ^p for full body", "PrFaint" } }
    for _, section in ipairs(outline) do
      local segs = { { HEADING_ICONS[section.level], "PrOrange" }, { section.title } }
      if section.note then segs[#segs + 1] = { " · " .. section.note, "PrMuted" } end
      left[#left + 1] = segs
    end
  end
  local files = pr.files or {}
  if #files > 0 then
    left[#left + 1] = {}
    left[#left + 1] = { { "files", "PrMuted" }, { " · " .. #files, "PrFaint" } }
    for i, file in ipairs(files) do
      if i > MAX_FILE_ROWS then
        left[#left + 1] = { { string.format("… +%d more", #files - MAX_FILE_ROWS), "PrMuted" } }
        break
      end
      local diff = string.format("+%d -%d", file.additions, file.deletions)
      left[#left + 1] = {
        { fit(file.path, left_w - width(diff) - 1) }, { " " },
        { "+" .. file.additions, "PrGreen" }, { " " }, { "-" .. file.deletions, "PrRed" },
      }
    end
  end

  local right = { { { "checks", "PrMuted" } } }
  local checks = checks_of(pr)
  for _, check in ipairs(checks) do
    right[#right + 1] = { { ICON[check.state], ICON_HL[check.state] }, { " " .. check.name } }
  end
  if #checks == 0 then right[#right + 1] = { { "–", "PrMuted" }, { " no checks" } } end
  right[#right + 1] = {}
  right[#right + 1] = { { "merge", "PrMuted" } }
  local status = pr_status(pr)
  local icon = GATE_ICON[status.gate]
  for i, part in ipairs(wrap(status.text, right_w - 2)) do
    right[#right + 1] = { { i == 1 and icon[1] or " ", icon[2] }, { " " .. part, icon[2] } }
  end
  if pr._fix then
    right[#right + 1] = {}
    right[#right + 1] = { { "fix", "PrMuted" } }
    for _, part in ipairs(wrap(pr._fix, right_w)) do right[#right + 1] = { { part, "PrCode" } } end
  end

  local out = {}
  for i = 1, math.max(#left, #right) do
    out[#out + 1] = to_ansi(concat(
      fit_line(left[i] or {}, left_w), { { " │ ", "PrFaint" } }, fit_line(right[i] or {}, right_w)
    ))
  end
  return out
end

local function pick_full(pr)
  local status = pr_status(pr)
  local icon = GATE_ICON[status.gate]
  local out = {
    to_ansi(title_line(pr)),
    to_ansi(concat(branch_segs(pr), { { "  · ", "PrDim" } }, diff_segs(pr))),
    to_ansi(concat(ci_summary(checks_of(pr)), { { "  " } }, { icon, { " " .. status.text, icon[2] } })),
    "",
  }
  local lines = body_lines(pr)
  local skip = fenced(lines)
  for i, line in ipairs(lines) do out[#out + 1] = to_ansi(md_segments(line, skip[i])) end
  return out
end

local function list_prs(dir, on_done)
  system({ "gh", "pr", "list", "--limit", "50", "--json", LIST_FIELDS }, dir, function(ok, out, err)
    if not ok then return on_done(nil, vim.trim(err)) end
    local prs = decode_json(out)
    if not prs then return on_done(nil, "gh pr list: bad JSON") end
    on_done(prs, out)
  end)
end

local function pick_entries(prs, list_w)
  local grouped = {}
  for _, pr in ipairs(prs) do
    local key = pr_status(pr).group
    grouped[key] = grouped[key] or {}
    table.insert(grouped[key], pr)
  end
  local entries = {}
  for _, group in ipairs(GROUPS) do
    for i, pr in ipairs(grouped[group.key] or {}) do
      local lines = {}
      if i == 1 then lines[1] = to_ansi(group_header(group, #grouped[group.key], list_w)) end
      for _, segs in ipairs(pick_row(pr, group.key, list_w)) do lines[#lines + 1] = to_ansi(segs) end
      entries[#entries + 1] = pr.number .. "\t" .. table.concat(lines, "\n")
    end
  end
  return entries
end

local pick_buf

local function open_picker(dir)
  setup_hl()
  local list_w = math.floor(vim.o.columns * 0.84) - 6
  local prs = list_cache[dir].prs
  local repo = (prs[1].url or ""):match("github%.com/([^/]+/[^/]+)/") or ""
  local info = string.format(
    [[c=$FZF_TOTAL_COUNT; [ "$FZF_MATCH_COUNT" = "$c" ] || c="$FZF_MATCH_COUNT/$c"; printf '%s%s · %s%s open%s' "$c"]],
    "\27[38;2;146;131;116m", repo, "\27[38;2;176;184;70m", "%s", "\27[0m"
  )

  local full = false
  local function pr_of(selected)
    local number = tonumber((selected and selected[1] or ""):match("^(%d+)"))
    for _, pr in ipairs(list_cache[dir] and list_cache[dir].prs or {}) do
      if pr.number == number then return pr end
    end
  end

  local function contents(fzf_cb)
    local entry = list_cache[dir]
    for _, line in ipairs(entry and pick_entries(entry.prs, list_w) or {}) do fzf_cb(line) end
    fzf_cb()
  end

  require("fzf-lua").fzf_exec(contents, {
    prompt = "PR> ",
    multiline = true,
    preview = function(items, _, cols)
      local pr = pr_of(items)
      if not pr then return "" end
      return table.concat(full and pick_full(pr) or pick_summary(pr, cols), "\n")
    end,
    keymap = { fzf = { start = "change-preview-window(wrap-word)" } },
    winopts = {
      width = 0.84,
      height = 0.92,
      title = false,
      preview = { layout = "vertical", vertical = "down:45%", wrap = true },
      on_create = function(e)
        pick_buf = e.bufnr
        vim.b[e.bufnr].pr_picker = true
        pcall(vim.api.nvim_win_set_config, e.winid, {
          footer = footer({
            { "enter", "review" }, { "^b", "browser" }, { "alt-m", "merge when CI passes" }, { "alt-y", "copy fix" },
            { "^p", "full preview" },
          }),
          footer_pos = "center",
        })
      end,
    },
    fzf_opts = {
      ["--ansi"] = true,
      ["--no-sort"] = true,
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--info"] = "inline-right",
      ["--info-command"] = info,
      ["--preview-wrap-sign"] = " ",
    },
    actions = {
      ["enter"] = function(selected)
        local pr = pr_of(selected)
        if pr then require("config.review_mode").start(tostring(pr.number), { base = pr.baseRefName }) end
      end,
      ["ctrl-b"] = {
        fn = function(selected)
          local pr = pr_of(selected)
          if pr then vim.fn.jobstart({ "gh", "pr", "view", tostring(pr.number), "--web" }, { cwd = dir, detach = true }) end
        end,
        exec_silent = true,
      },
      ["alt-y"] = {
        fn = function(selected) copy_fix(pr_of(selected)) end,
        exec_silent = true,
      },
      ["alt-m"] = function(selected)
        local pr = pr_of(selected)
        if pr then merge_pr(dir, pr.number, {}, function() end) end
      end,
      ["ctrl-p"] = {
        fn = function() full = not full end,
        exec_silent = true,
        postfix = "refresh-preview",
      },
      ["ctrl-r"] = { fn = function() end, reload = true },
    },
  })
end

-- Cached per repo like the detail view: reopening is instant, and a stale copy
-- is refreshed in the background and reloaded into the open picker.
function M.pick()
  if vim.fn.executable("gh") == 0 then
    vim.notify("gh CLI required", vim.log.levels.ERROR)
    return
  end
  local dir = vim.fs.root(0, ".git") or vim.uv.cwd()
  local entry = list_cache[dir]

  local function refresh(on_done)
    list_prs(dir, function(prs, raw)
      if not prs then return on_done(false, raw) end
      annotate(dir, prs, function()
        local changed = not list_cache[dir] or list_cache[dir].raw ~= raw
        list_cache[dir] = { prs = prs, raw = raw, at = now() }
        on_done(changed)
      end)
    end)
  end

  if entry and #entry.prs > 0 then
    open_picker(dir)
    if now() - entry.at < CACHE_TTL then return end
    refresh(function(changed)
      if changed and pick_buf and vim.api.nvim_buf_is_valid(pick_buf) then
        vim.api.nvim_chan_send(vim.bo[pick_buf].channel, "\18")
      end
    end)
    return
  end

  refresh(function(_, err)
    if err then return vim.notify(err, vim.log.levels.ERROR) end
    if #list_cache[dir].prs == 0 then return vim.notify("No open PRs", vim.log.levels.INFO) end
    open_picker(dir)
  end)
end

return M
