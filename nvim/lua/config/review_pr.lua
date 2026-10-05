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

local function behind_graph(pr, now_marker)
  local counts = tally(checks_of(pr))
  local mark = { "– no CI", "PrMuted" }
  if counts.pending > 0 then
    mark = { "● CI running here", "PrYellow" }
  elseif counts.total > 0 and counts.pass == counts.total then
    mark = { "✓ CI ran here", "PrGreen" }
  end
  local graph = string.rep("──●", 1 + math.min(3, pr._behind.count))
  return {
    {
      { pr.baseRefName, "PrAqua" }, { " " .. graph, "PrMuted" }, { " " .. refs_text(pr._behind), "PrYellow" },
      { now_marker and " ← now" or "", "PrMuted" },
    },
    {
      { string.rep(" ", width(pr.baseRefName) + 3) }, { "└──● ", "PrMuted" },
      { "#" .. pr.number .. " ", "PrYellow" }, mark,
    },
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
      sections[#sections + 1] = { level = math.min(#hashes, 6), title = title, items = 0, lines = 0, fields = {} }
    elseif #sections > 0 then
      local section = sections[#sections]
      local label, value = vim.trim(line):match("^%*%*([^*]+):%*%*%s*(.+)$")
      if vim.trim(line) ~= "" then section.lines = section.lines + 1 end
      if skip[i] or line:match("^%s*[-*+]%s+%[.%]") then
      elseif label and #value <= 40 then
        section.fields[#section.fields + 1] = label .. ": " .. plain_md(value)
      elseif is_list_item(line) then
        section.items = section.items + 1
      elseif not section.text and vim.trim(line) ~= "" then
        section.text = plain_md(vim.trim(line))
      end
    end
  end
  for _, section in ipairs(sections) do
    if #section.fields > 0 then
      section.note = table.concat(section.fields, " · ")
    elseif section.items > 0 then
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

-- Merge fallout: behind detection, conflict fixes, stacked PRs

local stacked_fixes = {}

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

local function fix_command(trees, main, branch, base, onto)
  local path = trees[branch]
  local origin = vim.fn.shellescape("origin/" .. base)
  local quoted = vim.fn.shellescape(branch)
  if onto then
    local go = path and ("cd " .. vim.fn.shellescape(path) .. " && git fetch")
      or ("git fetch && git switch " .. quoted)
    return string.format("%s && git rebase --onto %s %s && git push --force-with-lease", go, origin, onto:sub(1, 12))
  end
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
-- command that rebases a conflicting or formerly stacked PR in its worktree).
local function annotate(dir, prs, on_done)
  base_shas(dir, prs, function(shas)
    local open = vim.tbl_filter(function(pr) return (pr.state or "OPEN") == "OPEN" and shas[pr.baseRefName] ~= nil end, prs)
    local pending = #open

    local function finish_all()
      local trees, main
      for _, pr in ipairs(prs) do
        local stacked = (stacked_fixes[dir] or {})[pr.number]
        pr._fix = stacked and stacked.sha == pr.headRefOid and stacked.cmd or nil
        if not pr._fix and pr.mergeable == "CONFLICTING" then
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

local function stacked_children(dir, pr, on_done)
  system({ "gh", "pr", "list", "--base", pr.headRefName, "--json", "number,title,headRefName,headRefOid" }, dir,
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

-- After a merge, re-checks the open PRs on the same base. GitHub recomputes
-- mergeability lazily, so it polls while any PR is UNKNOWN.
local function report_fallout(dir, merged, children, before, on_done, polls)
  polls = polls or 0
  system({ "gh", "pr", "list", "--base", merged.baseRefName, "--limit", "50", "--json", LIST_FIELDS }, dir,
    function(ok, out)
      local prs = ok and decode_json(out) or nil
      if not prs then return on_done(nil) end
      local unknown = vim.iter(prs):any(function(pr) return pr.mergeable == "UNKNOWN" end)
      if unknown and polls < REPORT_POLLS then
        return vim.defer_fn(function()
          report_fallout(dir, merged, children, before, on_done, polls + 1)
        end, 3000)
      end
      annotate(dir, prs, function()
        local items, stacked = {}, {}
        for _, child in ipairs(children) do
          stacked[child.number] = true
          items[#items + 1] = {
            number = child.number,
            icon = "↳",
            hl = "PrBlue",
            text = "was stacked on #" .. merged.number,
            fix = stacked_fixes[dir][child.number].cmd,
            onto = stacked_fixes[dir][child.number].onto,
            branch = child.headRefName,
            base = merged.baseRefName,
            title = child.title,
          }
        end
        for _, pr in ipairs(prs) do
          if not stacked[pr.number] then
            if pr.mergeable == "CONFLICTING" and not before[pr.number] then
              items[#items + 1] = {
                number = pr.number,
                icon = "✗",
                hl = "PrRed",
                text = "now conflicts with " .. pr.baseRefName,
                fix = pr._fix,
                branch = pr.headRefName,
                base = pr.baseRefName,
                title = pr.title,
              }
            elseif pr.mergeable == "UNKNOWN" then
              items[#items + 1] = { number = pr.number, icon = "○", hl = "PrDim", text = "GitHub has not computed conflicts yet" }
            elseif pr._behind and pr.mergeable ~= "CONFLICTING" then
              local refs = refs_text(pr._behind)
              items[#items + 1] = {
                number = pr.number,
                icon = "↓",
                hl = "PrYellow",
                text = pr._behind.count .. " behind " .. pr.baseRefName .. (refs ~= "" and " (" .. refs .. ")" or ""),
                note = pr.isDraft and " · draft" or nil,
              }
            end
          end
        end
        on_done(items)
      end)
    end)
end

local function snapshot(dir, pr, on_done)
  system({ "gh", "pr", "list", "--base", pr.baseRefName, "--limit", "50", "--json", "number,mergeable" }, dir,
    function(ok, out) on_done(conflicting_numbers(ok and decode_json(out) or nil)) end)
end

-- Merge records: one per merge_pr call, driven by attempt() and shown by config.merges.

M.merges = {}
M.unseen = nil
M.settle_ms = 5000
M.ci_timeout = 3600

local SETTLE_POLLS = 24
local STEPS = { "open", "conflicts", "behind", "ci", "squash", "others" }
M.STEPS = STEPS

local function changed() vim.api.nvim_exec_autocmds("User", { pattern = "PrMergesChanged", modeline = false }) end

local function set(m, fields)
  for key, value in pairs(fields) do m[key] = value end
  changed()
end

local function finish(m, state, fields)
  if m.finished then return end
  m.answer = nil
  if m.cleanup then m.cleanup(m) end
  set(m, vim.tbl_extend("force", fields or {}, { state = state, finished = os.time() }))
  M.unseen = m
end

local function guard(m, fn)
  return function(...)
    if m.finished then return end
    local ok, err = pcall(fn, ...)
    if not ok then
      finish(m, "failed", { reason = "error: " .. tostring(err) })
      error(err, 0)
    end
  end
end

local function clock(secs) return string.format("%d:%02d", math.floor(secs / 60), math.floor(secs % 60)) end

local function capitalize(text) return text:sub(1, 1):upper() .. text:sub(2) end

local function first_failed_url(pr)
  for _, check in ipairs(checks_of(pr)) do
    if check.state == "fail" and check.url then return check.url end
  end
end

local function names_of(checks, state)
  local names = {}
  for _, check in ipairs(checks) do
    if check.state == state then names[#names + 1] = check.name end
  end
  return names
end

-- What must settle before the merge decision can be trusted: the step it blocks and why.
local function unsettled(pr, counts, opts)
  if pr.mergeable == "UNKNOWN" then return "conflicts", "GitHub is computing conflicts" end
  if opts.updated then
    if pr.headRefOid == opts.from then return "behind", "the branch update has not landed yet" end
    if counts.total == 0 then return "ci", "CI has not started after the branch update" end
  end
end

-- opts.updated/opts.from: branch updated from that head, opts.force: merge as tested,
-- opts.polls: settle retries so far.
local function attempt(m, opts)
  local dir, number = m.dir, m.number

  local function again(next_opts)
    vim.defer_fn(guard(m, function() attempt(m, next_opts) end), M.settle_ms)
  end

  local function block(pr, status, counts)
    local started = opts.updated or m.ci_since or m.answered
    if not started then
      if pr.isDraft then return finish(m, "refused", { reason = "draft · nothing started", draft = true }) end
      if pr.mergeable == "CONFLICTING" then
        return finish(m, "refused", { reason = "conflicts with " .. pr.baseRefName .. " · f fix", fix = pr._fix, conflict = true })
      end
      if counts.fail > 0 then
        return finish(m, "refused", {
          reason = "CI failed: " .. table.concat(names_of(checks_of(pr), "fail"), ", ") .. " · nothing started",
          note = "Fix the failing checks and push, then r retries.",
          log_url = first_failed_url(pr),
        })
      end
      return finish(m, "refused", { reason = status.reason .. " · nothing started" })
    end
    if counts.fail > 0 and status.reason:match("failed$") then
      local note = "Nothing was merged."
      if m.updated_with and m.passed_before then
        note = "Passed before the update, so " .. m.updated_with .. " likely broke it. Nothing was merged."
      end
      local failed = names_of(checks_of(pr), "fail")
      return finish(m, "failed", {
        reason = "CI failed" .. (m.updated_with and " with " .. m.updated_with or "") .. ": " .. table.concat(failed, ", "),
        note = note,
        log_url = first_failed_url(pr),
      })
    end
    local fix = pr.mergeable == "CONFLICTING" and pr._fix or nil
    return finish(m, "failed", { reason = status.reason, fix = fix, note = "Nothing was merged." })
  end

  local function update(pr, counts)
    local refs = refs_text(pr._behind)
    set(m, {
      state = "updating",
      step = "behind",
      detail = "Updating the branch with " .. pr.baseRefName .. (refs ~= "" and " (" .. refs .. ")" or "") .. ".",
      updated_with = refs,
      passed_before = counts.total > 0 and counts.pass == counts.total,
      answered = "update",
    })
    system({ "gh", "pr", "update-branch", tostring(number) }, dir, guard(m, function(ok, _, err)
      if not ok then
        local trees, main = worktrees(dir)
        return finish(m, "failed", {
          reason = "could not update with " .. pr.baseRefName .. ": " .. vim.trim(err),
          fix = fix_command(trees, main, pr.headRefName, pr.baseRefName),
          note = "Nothing was merged.",
        })
      end
      again({ updated = true, from = pr.headRefOid })
    end))
  end

  local function squash(pr, counts)
    stacked_children(dir, pr, guard(m, function(children)
      local head = pr.headRefOid
      local sha7 = head:sub(1, 7)
      set(m, {
        state = "squashing",
        step = "squash",
        head = head,
        detail = (counts.total > 0 and "All green on " or "No CI checks on ") .. sha7 .. ". Squash-merging that exact commit.",
      })
      snapshot(dir, pr, guard(m, function(before)
        m.squash_sent = true
        system({ "gh", "pr", "merge", tostring(number), "--squash", "--match-head-commit", head }, dir,
          guard(m, function(ok, _, err)
            if not ok then
              return finish(m, "failed", { reason = "squash failed: " .. vim.trim(err), note = "Nothing was merged." })
            end
            local listed = list_cache[dir]
            if listed then
              listed.prs = vim.tbl_filter(function(open) return open.number ~= number end, listed.prs)
              listed.at = 0
            end
            for key, entry in pairs(cache) do
              if entry.pr.number == number then cache[key] = nil end
            end
            if #children > 0 then
              local trees, main = worktrees(dir)
              stacked_fixes[dir] = stacked_fixes[dir] or {}
              for _, child in ipairs(children) do
                stacked_fixes[dir][child.number] = {
                  sha = child.headRefOid,
                  onto = head,
                  cmd = fix_command(trees, main, child.headRefName, pr.baseRefName, head),
                }
              end
            end
            local summary = counts.total > 0 and string.format("squashed after CI %d/%d", counts.pass, counts.total)
              or "squashed, no CI checks"
            if m.answered == "update" and m.updated_with and m.updated_with ~= "" then
              summary = summary .. " with " .. m.updated_with
            elseif m.answered == "tested" and m.behind then
              summary = summary .. ", without " .. refs_text(m.behind) .. " in CI"
            end
            local tree = worktrees(dir)[pr.headRefName]
            if tree then summary = summary .. " · worktree " .. vim.fn.fnamemodify(tree, ":~") .. " can go" end
            finish(m, "merged", { summary = summary })
            system({ "gh", "pr", "view", tostring(number), "--json", "mergeCommit", "--jq", ".mergeCommit.oid" }, dir,
              function(sha_ok, oid)
                oid = vim.trim(oid)
                if sha_ok and oid ~= "" then set(m, { sha = oid:sub(1, 7) }) end
              end)
            report_fallout(dir, pr, children, before, function(items)
              set(m, { fallout = items or false })
              if items then require("config.pr_fix").probe(m) end
            end)
          end))
      end))
    end))
  end

  view_pr(number, dir, guard(m, function(pr)
    if not pr then return finish(m, "failed", { reason = "could not read PR #" .. number }) end
    set(m, { pr = pr, title = pr.title, url = pr.url })
    annotate(dir, { pr }, guard(m, function()
      local listed = list_cache[dir]
      for i, open in ipairs(listed and listed.prs or {}) do
        if open.number == number then listed.prs[i] = pr end
      end
      local status = pr_status(pr)
      local counts = tally(checks_of(pr))
      m.ci = counts
      if status.gate == "blocked" then return block(pr, status, counts) end

      local step, why = unsettled(pr, counts, opts)
      if why then
        local polls = (opts.polls or 0) + 1
        local limit = clock(SETTLE_POLLS * M.settle_ms / 1000)
        if polls > SETTLE_POLLS then
          return finish(m, "failed", { reason = why .. " · gave up at " .. limit, note = "Nothing was merged." })
        end
        set(m, {
          state = opts.updated and "updating" or "checking",
          step = step,
          detail = capitalize(why) .. string.format(". Asks every %gs, gives up at %s.", M.settle_ms / 1000, limit),
        })
        return again(vim.tbl_extend("force", opts, { polls = polls }))
      end

      if pr._behind and not opts.force and not opts.updated then
        m.detail = nil
        return set(m, {
          state = "asking",
          step = "behind",
          behind = pr._behind,
          answer = function(choice)
            m.answer = nil
            if choice == "tested" then
              set(m, { state = "checking", answered = "tested" })
              return attempt(m, vim.tbl_extend("force", opts, { force = true, polls = 0 }))
            end
            update(pr, counts)
          end,
        })
      end

      if counts.pending > 0 then
        m.ci_since = m.ci_since or os.time()
        local elapsed = os.time() - m.ci_since
        if elapsed > M.ci_timeout then
          return finish(m, "failed", { reason = "CI still running after " .. clock(elapsed), note = "Nothing was merged." })
        end
        local pending = vim.tbl_filter(function(check) return check.state == "pending" end, checks_of(pr))
        local more = #pending > 1 and " +" .. (#pending - 1) or ""
        set(m, {
          state = "ci",
          step = "ci",
          detail = vim.trim(pending[1].name .. " " .. pending[1].detail) .. more .. " · merges by itself when green",
        })
        return again(vim.tbl_extend("force", opts, { polls = 0 }))
      end

      squash(pr, counts)
    end))
  end))
end

local function track(record)
  local today = os.time(vim.tbl_extend("force", os.date("*t"), { hour = 0, min = 0, sec = 0 }))
  for i = #M.merges, 1, -1 do
    local finished = M.merges[i].finished
    if finished and finished < today then table.remove(M.merges, i) end
  end
  table.insert(M.merges, 1, record)
  changed()
end

local function untrack(record)
  for i, m in ipairs(M.merges) do
    if m == record then return table.remove(M.merges, i) end
  end
end

function M.merge_pr(dir, number, opts)
  for i = #M.merges, 1, -1 do
    local m = M.merges[i]
    if m.kind ~= "fix" and m.dir == dir and m.number == number then
      if not m.finished then return m end
      if m.state == "refused" then table.remove(M.merges, i) end
    end
  end
  local m = { dir = dir, number = number, title = opts and opts.title or "PR #" .. number, started = os.time(), state = "checking", step = "open" }
  track(m)
  attempt(m, {})
  return m
end

function M.answer_merge(m, choice)
  if m.answer then m.answer(choice) end
end

function M.cancel_merge(m)
  if m.finished or m.squash_sent then return end
  finish(m, "failed", { reason = "cancelled", note = "Nothing was merged." })
end

function M.retry_merge(m)
  untrack(m)
  return M.merge_pr(m.dir, m.number, { title = m.title })
end

function M.ready_and_merge(m, on_done)
  system({ "gh", "pr", "ready", tostring(m.number) }, m.dir, function(ok, _, err)
    if not ok then return set(m, { reason = "could not mark ready: " .. vim.trim(err) }) end
    local retried = M.retry_merge(m)
    if on_done then on_done(retried) end
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

M.core = {
  plural = plural,
  system = system,
  set = set,
  finish = finish,
  guard = guard,
  changed = changed,
  view_pr = view_pr,
  checks_of = checks_of,
  tally = tally,
  names_of = names_of,
  refs_of = refs_of,
  refs_text = refs_text,
  clock = clock,
  track = track,
  untrack = untrack,
  parse_worktrees = parse_worktrees,
  SETTLE_POLLS = SETTLE_POLLS,
}

M.ui = {
  setup_hl = setup_hl,
  fit = fit,
  fit_line = fit_line,
  wrap = wrap,
  to_buf = to_buf,
  footer = footer,
  width = width,
  clock = clock,
  copy_fix = copy_fix,
  behind_segs = behind_segs,
  behind_graph = behind_graph,
  refs_text = refs_text,
  ci_estimate = ci_estimate,
}

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
  map("<M-y>", function() copy_fix(cache[key] and cache[key].pr._fix) end)
  map("<C-b>", function()
    local current = cache[key]
    if not current then return end
    vim.fn.jobstart({ "gh", "pr", "view", tostring(current.pr.number), "--web" }, { cwd = dir, detach = true })
  end)
  map("M", function()
    local current = cache[key]
    if not current then return vim.notify("Still loading the PR", vim.log.levels.INFO) end
    close()
    local m = M.merge_pr(dir, current.pr.number, { title = current.pr.title })
    require("config.merges").open(m)
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
  { key = "merging", label = "◐ in progress", hl = "PrGroupWaiting" },
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

local MERGE_STATES = { checking = "checking", updating = "updating the branch", asking = "needs you", squashing = "squashing" }

local FIX_STATES = {
  fetching = "fetching", merging = "merging master", rebasing = "rebasing", resolving = "needs you", ready = "ready to push",
  pushing = "pushing", dirty = "needs you", no_worktree = "needs you", paused = "paused",
}

local function running_merge(dir, number)
  return vim.iter(M.merges):find(function(m) return m.dir == dir and m.number == number and not m.finished end)
end

local function job_label(m)
  local ci = m.ci and string.format("CI %d/%d", m.ci.pass, m.ci.total)
  if m.kind ~= "fix" then return "merging · " .. (m.state == "ci" and ci or MERGE_STATES[m.state] or m.state) end
  local claude = m.ai and require("config.pr_ai").label(m)
  if claude then return "Claude · " .. claude end
  return "fixing · " .. (m.state == "ci" and ci or FIX_STATES[m.state] or m.state)
end

local function merging_status(m)
  local label = job_label(m)
  local waiting = label:match("needs you") or label:match("unsure") or label:match("ready") or label:match("gave up") or label:match("failed")
  return { { "      " }, { "●", "PrYellow" }, { " " .. label, waiting and "PrTitle" or "PrDim" }, { "  <leader>gM", "PrMuted" } }
end

local function pick_row(pr, group, w, merge)
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

  if merge then return { first, fit_line(merging_status(merge), w) } end
  local status = concat({ { "      " } }, ci_short(checks_of(pr)), { { "  " } }, review_status(pr))
  if pr.mergeable == "CONFLICTING" then
    status = concat(status, { { "  " }, { "✗", "PrRed" }, { " conflicts" } })
  elseif group == "ready" and pr.mergeable == "MERGEABLE" and not pr._behind then
    status = concat(status, { { "  " }, { "✓", "PrGreen" }, { " mergeable" } })
  end
  if behind_visible(pr) then status = concat(status, { { "  " } }, behind_segs(pr)) end
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
  if pr._behind then right[1][2] = { " · " .. ran_before(pr), "PrFaint" } end
  local checks = checks_of(pr)
  for _, check in ipairs(checks) do
    right[#right + 1] = { { ICON[check.state], ICON_HL[check.state] }, { " " .. check.name } }
  end
  if #checks == 0 then right[#right + 1] = { { "–", "PrMuted" }, { " no checks" } } end
  if behind_visible(pr) then
    right[#right + 1] = {}
    right[#right + 1] = { { "base", "PrMuted" } }
    vim.list_extend(right, behind_graph(pr, true))
    local counts = tally(checks)
    if counts.total > 0 and counts.pass == counts.total then
      local refs = refs_text(pr._behind)
      local lacking = refs ~= "" and refs or "those commits"
      local sentence = string.format(
        "↓%d behind %s. CI passed without %s, so #%d and %s have not been tested together.",
        pr._behind.count, pr.baseRefName, lacking, pr.number, lacking
      )
      for _, part in ipairs(wrap(sentence, right_w)) do right[#right + 1] = { { part, "PrMuted" } } end
    end
  end
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

local function pick_entries(prs, list_w, dir)
  local grouped, merging = {}, {}
  for _, pr in ipairs(prs) do
    merging[pr.number] = dir and running_merge(dir, pr.number)
    local key = merging[pr.number] and "merging" or pr_status(pr).group
    grouped[key] = grouped[key] or {}
    table.insert(grouped[key], pr)
  end
  local entries = {}
  for _, group in ipairs(GROUPS) do
    for i, pr in ipairs(grouped[group.key] or {}) do
      local lines = {}
      if i == 1 then lines[1] = to_ansi(group_header(group, #grouped[group.key], list_w)) end
      for _, segs in ipairs(pick_row(pr, group.key, list_w, merging[pr.number])) do lines[#lines + 1] = to_ansi(segs) end
      entries[#entries + 1] = pr.number .. "\t" .. table.concat(lines, "\n")
    end
  end
  return entries
end

local pick_buf

local function merges_signature(dir)
  local parts = {}
  for _, m in ipairs(M.merges) do
    if m.dir == dir then
      local phase = m.ai and m.ai.phase or ""
      parts[#parts + 1] = table.concat({ m.number, m.finished and "done" or m.state, phase, m.ci and m.ci.pass or "" }, ":")
    end
  end
  return table.concat(parts, ",")
end

-- when_ready(fn) runs fn once the PR list has loaded; the picker opens before
-- that and shows "loading" while the marker file exists.
local function open_picker(dir, when_ready, loading_marker)
  setup_hl()
  local list_w = math.floor(vim.o.columns * 0.84) - 6
  local remote = vim.trim(vim.fn.system({ "git", "-C", dir, "remote", "get-url", "origin" }))
  local repo = remote:match("github%.com[:/]([^/]+/[^/]-)%.git$") or remote:match("github%.com[:/]([^/]+/[^/]+)$") or ""
  local loading = loading_marker
      and string.format([[[ -e %s ] && { printf '%s%s · loading from GitHub…%s'; exit; }; ]],
        vim.fn.shellescape(loading_marker), "\27[38;2;146;131;116m", repo, "\27[0m")
    or ""
  local info = loading .. string.format(
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
    local function feed()
      local entry = list_cache[dir]
      for _, line in ipairs(entry and pick_entries(entry.prs, list_w, dir) or {}) do fzf_cb(line) end
      fzf_cb()
    end
    if when_ready then return when_ready(feed) end
    feed()
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
        local shown = merges_signature(dir)
        vim.api.nvim_create_autocmd("User", {
          pattern = "PrMergesChanged",
          callback = function()
            if not vim.api.nvim_buf_is_valid(e.bufnr) then return true end
            local now_shown = merges_signature(dir)
            if now_shown == shown then return end
            shown = now_shown
            pcall(vim.api.nvim_chan_send, vim.bo[e.bufnr].channel, "\18")
          end,
        })
        pcall(vim.api.nvim_win_set_config, e.winid, {
          footer = footer({
            { "enter", "review" }, { "^b", "browser" }, { "alt-m", "merge when CI passes" }, { "alt-c", "Claude fixes conflicts" }, { "alt-r", "merges" },
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
        if pr then M.review(dir, pr) end
      end,
      ["ctrl-b"] = {
        fn = function(selected)
          local pr = pr_of(selected)
          if pr then vim.fn.jobstart({ "gh", "pr", "view", tostring(pr.number), "--web" }, { cwd = dir, detach = true }) end
        end,
        exec_silent = true,
      },
      ["alt-r"] = function() vim.schedule(function() require("config.merges").open() end) end,
      ["alt-m"] = function(selected)
        local pr = pr_of(selected)
        if pr then
          local m = M.merge_pr(dir, pr.number, { title = pr.title })
          vim.schedule(function() require("config.merges").open(m) end)
        end
      end,
      ["alt-c"] = function(selected)
        local pr = pr_of(selected)
        if pr and pr.mergeable == "CONFLICTING" then
          local r = require("config.pr_ai").start_pr(dir, pr)
          vim.schedule(function() require("config.merges").open(r) end)
        end
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

  local marker = vim.fn.tempname()
  vim.fn.writefile({}, marker)
  local loaded, waiting = false, {}
  refresh(function(_, err)
    loaded = true
    vim.fn.delete(marker)
    if err then vim.notify(err, vim.log.levels.ERROR) end
    for _, feed in ipairs(waiting) do feed() end
  end)
  open_picker(dir, function(feed)
    if loaded then return feed() end
    waiting[#waiting + 1] = feed
  end, marker)
end

M.views = { pick_row = pick_row, pick_summary = pick_summary, detail_header = detail_header }

return M
