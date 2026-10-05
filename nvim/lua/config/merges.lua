local M = {}

local review = require("config.review_pr")
local fix = require("config.pr_fix")
local pr_ai = require("config.pr_ai")
local ui = review.ui

local view
local hover
local close
local RECENT = 600

local STATE_HEAD = {
  checking = { "●", "PrYellow", "checking", "PrYellow" },
  updating = { "●", "PrYellow", "updating", "PrYellow" },
  ci = { "●", "PrYellow", "CI", "PrYellow" },
  asking = { "●", "PrYellow", "needs you", "PrTitle" },
  squashing = { "●", "PrGreen", "squashing", "PrGreen" },
  merged = { "✓", "PrGreen", "merged", "PrDim" },
  failed = { "✗", "PrRed", "not merged", "PrRed" },
  refused = { "✗", "PrOrange", "refused", "PrOrange" },
}

local FIX_HEAD = {
  fetching = { "●", "PrYellow", "fetching", "PrYellow" },
  merging = { "●", "PrYellow", "merging", "PrYellow" },
  rebasing = { "●", "PrYellow", "rebasing", "PrYellow" },
  resolving = { "●", "PrYellow", "needs you", "PrTitle" },
  ready = { "●", "PrGreen", "ready to push", "PrGreen" },
  pushing = { "●", "PrYellow", "pushing", "PrYellow" },
  ci = { "●", "PrYellow", "CI", "PrYellow" },
  plan = { "◆", "PrYellow", "plan ready", "PrYellow" },
  dirty = { "!", "PrOrange", "not started", "PrOrange" },
  no_worktree = { "!", "PrOrange", "not started", "PrOrange" },
  paused = { "⏸", "PrYellow", "", "PrMuted" },
  fixed = { "✓", "PrGreen", "", "PrDim" },
  aborted = { "–", "PrMuted", "", "PrMuted" },
  failed = { "✗", "PrRed", "not fixed", "PrRed" },
}

local plural = review.core.plural

local function ci_label(m)
  local ci = m.ci
  return ci and ci.total > 0 and string.format("CI %d/%d", ci.pass, ci.total) or "CI"
end

local function age_text(m)
  local secs = os.time() - m.finished
  if secs < RECENT then return ui.clock(m.finished - m.started) end
  if secs < 3600 then return math.floor(secs / 60) .. "m ago" end
  return math.floor(secs / 3600) .. "h ago"
end

local unresolved = pr_ai.unresolved

local function fix_title(r)
  if r.state == "aborted" then return (r.headline or "") .. (r.ai and r.ai.log and " · t transcript for 24h" or "") end
  if r.finished then return r.reason or "" end
  if r.state == "dirty" then return "worktree has uncommitted changes" end
  if r.state == "no_worktree" then return "no worktree for " .. r.branch end
  if r.state == "paused" then
    local first = unresolved(r)[1]
    if not first then return "paused · merge commit not pushed" end
    return string.format("paused · resolve %d/%d, %s still has %s", #r.files - #unresolved(r), #r.files, first.path, plural(first.markers, "marker"))
  end
  if r.stacked then return "↳ was stacked" .. (r.from and " on #" .. r.from or "") .. " · now targets " .. r.base end
  return r.title or ""
end

local function fix_head(m)
  local unsure = m.ai and m.state == "resolving" and #pr_ai.unsure_paths(m) or 0
  if unsure > 0 and m.ai.phase == "review" then return { "?", "PrOrange", "needs you · " .. unsure .. " unsure", "PrTitle" } end
  return FIX_HEAD[m.state]
end

local function head_line(m, w)
  local fixing = m.kind == "fix"
  local head = fixing and fix_head(m) or STATE_HEAD[m.state]
  local text = head[3]
  if m.state == "ci" then text = ci_label(m) end
  if m.state == "merging" then text = "merging " .. m.base end
  if m.state == "merged" and m.sha then text = m.sha end
  local time = m.finished and age_text(m) or ui.clock(os.time() - m.started)
  if m.state == "paused" then time = math.floor((os.time() - m.started) / 60) .. "m" end
  local name = fixing and "fix #" or "#"
  local prefix = { { head[1], head[2] }, { " " }, { name .. m.number, "PrTitle" }, { " " } }
  local right = { { text, head[4] }, { " " }, { time, "PrMuted" } }
  local used = ui.width(head[1] .. " " .. name .. m.number .. " ") + ui.width(text .. " " .. time) + 1
  local title = fixing and fix_title(m) or m.title or ""
  local line = vim.list_extend(prefix, { { ui.fit(title, w - used) }, { " " } })
  return ui.fit_line(vim.list_extend(line, right), w)
end

local function fix_chip(m, step, kind)
  local pushed = m.pushed and m.pushed:sub(1, 7)
  if step == "plan" or step == "run" then return step end
  if step == "review" then
    if kind == "done" then return m.ai and m.ai.plan and "checked against plan" or "checked" end
    local flagged = m.ai and m.ai.flagged or 0
    return kind == "current" and string.format("review %d/%d", flagged - #pr_ai.unsure_paths(m), flagged) or "review"
  end
  if step == "clean" then return m.stashed and "stashed" or "worktree clean" end
  if step == "fetch" then return "fetch" end
  if step == "merge" then return "merge " .. m.base end
  if step == "resolve" then
    if kind == "pending" then return "resolve" end
    if kind == "done" and #m.files == 0 then return "no conflicts" end
    return string.format("resolve %d/%d", #m.files - #unresolved(m), #m.files)
  end
  if step == "rebase" then
    if kind == "pending" or not m.total then return "rebase --onto " .. m.base end
    return string.format("rebase --onto %s %d/%d", m.base, kind == "done" and m.total or m.cur, m.total)
  end
  if step == "push" then
    local verb = m.stacked and "force-push" or "push"
    return kind == "done" and pushed and verb:gsub("push", "pushed") .. " " .. pushed or verb
  end
  return ci_label(m)
end

local function chip_label(m, step, kind)
  local base = m.pr and m.pr.baseRefName or "behind"
  if step == "open" then return "open" end
  if step == "conflicts" then return kind == "done" and "no conflicts" or "conflicts?" end
  if step == "behind" then
    if kind == "pending" then return base end
    if kind == "current" then return m.state == "asking" and "behind" or "updating" end
    if m.answered == "update" then
      return (m.updated_with or "") ~= "" and "updated with " .. m.updated_with or "updated"
    end
    return m.answered == "tested" and "as tested" or "up to date"
  end
  if step == "ci" then
    if kind == "pending" then return "CI" end
    if kind == "done" and not (m.ci and m.ci.total > 0) then return "no CI" end
    return ci_label(m)
  end
  if step == "squash" then return kind == "done" and "squashed" or "squash" end
  return "others"
end

local function chips_line(m)
  local steps = review.STEPS
  if m.kind == "fix" and m.ai then
    steps = fix.STEPS.ai
  elseif m.kind == "fix" and m.stacked then
    steps = fix.STEPS.stacked
  elseif m.kind == "fix" then
    steps = fix.STEPS.merge
  end
  local cur = vim.fn.index(steps, m.step) + 1
  if m.state == "plan" then cur = cur + 0.5 end
  local segs = { { "  " } }
  for i, step in ipairs(steps) do
    local label = m.kind == "fix" and fix_chip or chip_label
    if i > 1 then segs[#segs + 1] = { "  " } end
    if i < cur or (step == "behind" and m.answered == "tested") then
      vim.list_extend(segs, { { "✓", "PrGreen" }, { " " .. label(m, step, "done"), "PrDim" } })
    elseif i == cur then
      local icon, hl = "●", (m.state == "squashing" or m.state == "ready") and "PrGreen" or "PrYellow"
      if m.state == "asking" then icon, hl = "↓", "PrYellow" end
      vim.list_extend(segs, { { icon, hl }, { " " .. label(m, step, "current"), "PrDim" } })
    else
      segs[#segs + 1] = { "○ " .. label(m, step, "pending"), "PrPending" }
    end
  end
  return segs
end

local function indented(segs) return vim.list_extend({ { "  " } }, segs) end

local function asking_lines(m)
  local pr = m.pr
  local lines = { indented({ { "You need to run CI again.", "PrTitle" } }) }
  for _, segs in ipairs(ui.behind_graph(pr)) do lines[#lines + 1] = indented(segs) end
  local refs = ui.refs_text(m.behind)
  vim.list_extend(lines, {
    indented({
      { " u ", "PrKey" },
      { "  update with " .. pr.baseRefName .. ", re-run CI, merge when green" },
      { "  " .. (ui.ci_estimate(pr) or ""), "PrMuted" },
    }),
    indented({
      { " m ", "PrTitle" },
      { "  merge as tested, without " .. (refs ~= "" and refs or "them") .. " in CI" },
      { "  now", "PrMuted" },
    }),
  })
  return lines
end

local function expanded_of(m)
  if m.expanded ~= nil then return m.expanded end
  return os.time() - m.finished < RECENT
end

local function wrapped(text, hl, w)
  local lines = {}
  for _, part in ipairs(ui.wrap(text, w - 2)) do lines[#lines + 1] = indented({ { part, hl } }) end
  return lines
end

local BOX = { ready = { "PrGreen", "PrBoxReady" }, wait = { "PrYellow", "PrBoxWait" }, blocked = { "PrOrange", "PrBoxBlocked" } }

local function pad(text, w) return text .. string.rep(" ", math.max(1, w - ui.width(text))) end

local function easy_rows(r, f)
  local rows = { { { f.path, "PrTitle" }, { "   the two edits touch neighbouring lines", "PrMuted" } } }
  local cluster = f.res.clusters[1]
  if not cluster then return rows end
  local lines, keeps, drops, col = {}, {}, {}, 0
  for _, e in ipairs(cluster.edits) do
    if e.side ~= "both" then
      local mine = e.side ~= "theirs"
      local who = mine and "#" .. r.number or r.base
      local tail = (mine or not r.from) and "" or " (#" .. r.from .. ")"
      for _, line in ipairs(e.removed) do
        local note = #e.lines == 0 and who .. " removed it" .. tail or who .. " changed it" .. tail
        lines[#lines + 1] = { sign = "- ", text = line, note = note, hl = "PrRed" }
        drops[#drops + 1] = fix.label(line)
      end
      for _, line in ipairs(e.lines) do
        local note = #e.removed == 0 and who .. " added it" .. tail or string.format("takes %s's %s", mine and who or r.base, fix.label(line))
        lines[#lines + 1] = { sign = "+ ", text = line, note = note, hl = "PrGreen" }
        keeps[#keeps + 1] = fix.label(line)
      end
    end
  end
  for _, line in ipairs(lines) do col = math.max(col, ui.width(line.sign .. line.text)) end
  if cluster.before then rows[#rows + 1] = { { "  " .. cluster.before, "PrDim" } } end
  for i, line in ipairs(lines) do
    if i <= 10 then rows[#rows + 1] = { { pad(line.sign .. line.text, col + 3), line.hl }, { line.note, "PrMuted" } } end
  end
  if cluster.after then rows[#rows + 1] = { { "  " .. cluster.after, "PrDim" } } end
  local parts = {}
  if #keeps > 0 then parts[#parts + 1] = "keeps " .. table.concat(keeps, ", ") end
  if #drops > 0 then parts[#parts + 1] = "drops " .. table.concat(drops, ", ") end
  local result = #parts > 0 and "Result: " .. table.concat(parts, ", ") .. ". Both changes survive." or "Result: both changes survive."
  rows[#rows + 1] = { { result, "PrTitle" } }
  return rows
end

local function real_rows(r, f)
  if f.kind == "other" then
    return {
      { { f.path, "PrTitle" }, { " · you decide", "PrMuted" } },
      { { f.why, "PrSoft" } },
      { { "resolve it in a terminal and git add it; this turns ✓ when the window opens again.", "PrMuted" } },
    }
  end
  local cluster = vim.iter(f.res.clusters):find(function(item) return item.hard end) or {}
  local label = pad(r.from and r.base .. " (#" .. r.from .. ")" or r.base, 16)
  return {
    { { string.format("%s:%d", f.path, cluster.pr_line or 1), "PrTitle" }, { " · you decide", "PrMuted" } },
    { { label, "PrMuted" }, { vim.trim((cluster.theirs or {})[1] or "(deleted)") } },
    { { pad("#" .. r.number, 16), "PrMuted" }, { vim.trim((cluster.ours or {})[1] or "(deleted)") } },
    { { "enter opens it with the markers; save without markers and this line turns ✓.", "PrMuted" } },
  }
end

local function commit_rows(r)
  local rows = {}
  for _, commit in ipairs(r.commits) do
    local icon, hl = "○", "PrPending"
    if commit.status == "done" then icon, hl = "✓", "PrGreen" end
    if commit.status == "current" then icon, hl = "●", "PrYellow" end
    if commit.status == "skipped" then icon, hl = "–", "PrMuted" end
    local text = commit.status == "skipped" and commit.note or commit.subject .. (commit.note and " · " .. commit.note or "")
    rows[#rows + 1] = { { icon, hl }, { " " .. commit.sha7 .. "  ", "PrDim" }, { text, commit.status == "pending" and "PrPending" or "PrSoft" } }
  end
  return rows
end

local function file_rows(r, w)
  local rows, col = {}, 0
  for _, f in ipairs(r.files) do col = math.max(col, ui.width(f.path)) end
  for _, f in ipairs(r.files) do
    local icon, hl, text = "✗", "PrRed", f.why and f.why .. " · resolve in a terminal" or ""
    if f.status == "accepted" or f.status == "resolved" then
      icon, hl, text = "✓", "PrGreen", f.status
    elseif f.status == "ready" then
      icon, hl, text = "◆", "PrYellow", "fix ready · a"
    elseif f.kind == "content" then
      local cluster = vim.iter(f.res.clusters):find(function(item) return item.hard end)
      text = "both changed line " .. (cluster and cluster.pr_line or 1) .. " · enter"
    end
    rows[#rows + 1] = { file = f, segs = { { icon, hl }, { " " }, { pad(f.path, col + 3) }, { text, "PrMuted" } } }
  end
  return rows
end

local function summary_rows(r)
  local groups, order = {}, {}
  local function add(key, icon, hl, label, path)
    if not groups[key] then
      groups[key] = { icon = icon, hl = hl, label = label, paths = {} }
      order[#order + 1] = key
    end
    table.insert(groups[key].paths, path)
  end
  for _, f in ipairs(r.files) do
    if f.status == "accepted" then
      add("easy", "=", "PrDim", "easy, fix accepted", f.path)
    elseif f.status == "resolved" then
      add("resolved", "✓", "PrGreen", "resolved", f.path)
    elseif f.status == "ready" then
      add("ready", "◆", "PrYellow", "fix ready · a", f.path)
    elseif f.kind == "content" then
      add("real", "✗", "PrRed", "both sides changed · enter · c", f.path)
    else
      add("other", "✗", "PrRed", "need you in a terminal", f.path)
    end
  end
  return vim.tbl_map(function(key)
    local group = groups[key]
    return { paths = group.paths, segs = { { group.icon, group.hl }, { " " .. #group.paths .. " " }, { group.label, "PrMuted" } } }
  end, order)
end

local function counts_segs(r)
  local counts = pr_ai.counts(r)
  local segs = {
    { "= " .. counts["="] .. " easy", "PrDim" }, { "  " }, { "◆ " .. counts["◆"] .. " Claude", "PrYellow" }, { "  " }, { "✎ " .. counts["✎"] .. " you", "PrGreen" },
    { "  " }, { "? " .. counts["?"] .. " unsure", "PrOrange" },
  }
  local fmt = r.ai.checks and r.ai.checks.fmt
  if fmt then vim.list_extend(segs, { { "  " }, { fmt.text, "PrGreen" } }) end
  return segs
end

local function shown_file(r)
  local files = unresolved(r)
  return vim.iter(files):find(function(f) return f.status == "real" end) or files[1]
end

local function writer(r, w, add)
  local out = { target = { merge = r } }
  function out.line(segs, hl) add(vim.list_extend({ { "  " } }, segs), out.target, hl) end
  function out.text(str, hl)
    for _, part in ipairs(ui.wrap(str, w - 4)) do out.line({ { part, hl or "PrMuted" } }) end
  end
  function out.box(kind, rows, file)
    local item_target = file and { merge = r, file = file } or out.target
    for _, segs in ipairs(rows) do
      add(vim.list_extend({ { "  ┃ ", BOX[kind][1] } }, segs), item_target, BOX[kind][2])
    end
  end
  function out.sentence(str, kind, file)
    local rows = {}
    for _, part in ipairs(ui.wrap(str, w - 8)) do rows[#rows + 1] = { { part, "PrSoft" } } end
    out.box(kind, rows, file)
  end
  function out.groups()
    for i, group in ipairs(r.ai.plan and r.ai.plan.groups or {}) do
      local check = r.ai.checks and r.ai.checks.groups[i] or {}
      local flagged = vim.iter(group.files):any(function(path) return r.marks[path] and r.marks[path].unsure end)
      local icon, hl = "◆", "PrYellow"
      if flagged then
        icon, hl = "?", "PrOrange"
      elseif check.ok then
        icon, hl = "✓", "PrGreen"
      end
      local text = check.text or (group.kind == "merge" and "merged by Claude · read these" or "")
      add(vim.list_extend({ { "  " } }, { { icon, hl }, { " " .. i .. " " .. #group.files .. " · " .. group.title .. "   " }, { text, "PrMuted" } }), { merge = r, group = i })
    end
  end
  return out
end

local function plan_rows(r, out, add)
  for i, group in ipairs(r.ai.plan.groups) do
    add(indented({
      { string.format("%-3d", i), "PrYellow" }, { string.format("%-6d", #group.files), "PrTitle" }, { pad(group.title, 32) }, { group.strategy, "PrMuted" },
    }), { merge = r, group = i })
  end
  out.text(r.ai.plan.summary, "PrSoft")
  out.text(string.format("%s nothing pushed · uses your Claude usage", r.ai.plan.minutes and "~" .. r.ai.plan.minutes .. " min ·" or ""))
  if r.ai.why then out.text(r.ai.why, "PrOrange") end
end

local function unsure_box(r, out, path, by_path)
  local unsure = r.marks[path].unsure
  local f = by_path[path]
  local cluster = f and f.res and vim.iter(f.res.clusters):find(function(item) return item.hard end)
  local rows = { { { string.format("%s:%s · %s", vim.fs.basename(path), unsure.line or "?", unsure.kind == "claude" and "Claude's guess" or "off-plan"), "PrTitle" } } }
  if cluster then
    rows[#rows + 1] = { { pad(r.from and r.base .. " (#" .. r.from .. ")" or r.base, 16), "PrMuted" }, { vim.trim((cluster.theirs or {})[1] or "(deleted)") } }
    rows[#rows + 1] = { { pad("#" .. r.number, 16), "PrMuted" }, { vim.trim((cluster.ours or {})[1] or "(deleted)") } }
  end
  rows[#rows + 1] = { { unsure.guess and "guess " .. unsure.guess or unsure.reason, "PrSoft" } }
  out.box("wait", rows, by_path[path] or { path = path, kind = "content" })
end

local function review_rows(r, out, add)
  out.line(counts_segs(r))
  out.groups()
  local paths = pr_ai.unsure_paths(r)
  local col = 0
  for _, path in ipairs(paths) do col = math.max(col, ui.width(path)) end
  local by_path = {}
  for _, f in ipairs(r.files) do by_path[f.path] = f end
  for _, path in ipairs(paths) do
    local unsure = r.marks[path].unsure
    local group = pr_ai.group_of(r.ai.plan, path)
    local label = "off-plan"
    if unsure.kind == "claude" then label = group and "group " .. group or "Claude" end
    local reason = (unsure.kind == "claude" and "Claude says unsure: " or "") .. unsure.reason
    add(indented({ { "? ", "PrOrange" }, { pad(path, col + 2) }, { pad(label, 10), "PrMuted" }, { reason, "PrSoft" } }), {
      merge = r, file = by_path[path] or { path = path, kind = "content" },
    })
  end
  local path = vim.tbl_contains(paths, hover) and hover or paths[1]
  if path then unsure_box(r, out, path, by_path) end
  out.text("There are two kinds of unsure: Claude said so, or it went off-plan. a marks the file ✎ as yours.")
end

local function resolving_rows(r, w, out, add)
  if #r.files > 20 then
    for _, row in ipairs(summary_rows(r)) do add(vim.list_extend({ { "  " } }, row.segs), { merge = r, paths = row.paths }) end
  elseif #r.files >= 2 then
    for _, row in ipairs(file_rows(r, w)) do add(vim.list_extend({ { "  " } }, row.segs), { merge = r, file = row.file }) end
  end
  local f = shown_file(r)
  if f and f.status == "ready" then
    out.box("wait", easy_rows(r, f), f)
  elseif f then
    out.box("blocked", real_rows(r, f), f)
  end
  local open = #unresolved(r)
  if open > 0 and not r.stacked then
    out.box("wait", { { { "◆ c: let Claude resolve the " .. open, "PrTitle" } } })
    out.sentence(string.format(
      "Runs claude -p in %s on this merge. Takes minutes and uses your Claude usage.%s",
      vim.fn.fnamemodify(r.path, ":~"), open >= pr_ai.plan_at and " Plans first." or ""
    ), "wait")
    out.sentence(string.format(
      "Stops at ready to push. Its files get ◆, yours ✎, easy ones =, files it's unsure about ?. x still goes back to %s.", r.orig:sub(1, 7)
    ), "wait")
  end
  if r.ai and r.ai.why then out.text(r.ai.why, "PrOrange") end
end

local function ready_ai_rows(r, out, add)
  out.line(counts_segs(r))
  out.groups()
  local reads = pr_ai.merge_paths(r)
  for i, path in ipairs(reads) do
    if i <= 20 then
      local icon, hl = pr_ai.mark_of(r, path)
      add(indented({ { icon, hl }, { " " .. path .. "   " }, { (r.marks[path] or {}).note or "", "PrMuted" } }), { merge = r, file = { path = path, kind = "content" } })
    end
  end
  if #reads > 20 then out.text("… " .. (#reads - 20) .. " more · ]q") end
  out.sentence(string.format(
    "Merge commit %s, not pushed. ]q visits merge groups first, then reapply; format groups only on request.", r.merge_sha:sub(1, 7)
  ), "ready")
  if r.ai.cost then out.sentence(string.format("Claude used $%.2f of usage.", r.ai.cost), "ready") end
end

local function ready_rows(r, out)
  local first = vim.iter(r.files):find(function(f) return f.status == "accepted" or f.status == "resolved" end)
  if r.stacked then
    return out.sentence(string.format(
      "Stacked PRs are rebased, not merged, so %s commits drop out. That rewrites history: pushing needs force, so the key is capital P.",
      r.from and "#" .. r.from .. "'s" or "the parent's"
    ), "wait")
  end
  local contains = #r.contains > 0 and " (" .. table.concat(r.contains, ", ") .. ")" or ""
  out.sentence(string.format("Merge commit %s on %s. Not pushed yet.", r.merge_sha:sub(1, 7), r.branch), "ready")
  out.sentence(string.format(
    "#%d now contains %s%s. Your own changes are untouched%s.", r.number, r.base, contains,
    first and "; " .. first.path .. " was resolved as shown" or ""
  ), "ready")
  out.sentence("Normal push: the merge only adds a commit, so no force is needed.", "ready")
end

local function fix_lines(r, w, add)
  local out = writer(r, w, add)
  local state = r.state
  if state == "dirty" then
    out.line({ { table.concat(r.dirty, " · "), "PrCode" } })
    return out.text(string.format(
      's stashes them, fixes, then puts them back. If putting them back conflicts, the stash is kept and named "fix #%d".', r.number
    ))
  elseif state == "no_worktree" then
    return out.text(string.format("w creates %s and continues · y copies the commands instead", vim.fn.fnamemodify(r.new_path, ":~")))
  elseif state == "paused" then
    return out.text("State is read from git each time the window opens, so it's right after closing Neovim.")
  end

  add(chips_line(r), out.target)
  if r.path and r.orig then
    local where = "in " .. vim.fn.fnamemodify(r.path, ":~") .. " · branch was at " .. r.orig:sub(1, 7)
    out.text(where .. (r.pushed and "" or ", x goes back there"))
  end
  if r.stacked and #r.commits > 0 then
    for _, segs in ipairs(commit_rows(r)) do out.line(segs) end
  end
  local reviewing = r.ai and (r.ai.phase == "review" or r.ai.phase == "done")
  if state == "plan" then
    plan_rows(r, out, add)
  elseif state == "resolving" and reviewing then
    review_rows(r, out, add)
  elseif state == "resolving" then
    resolving_rows(r, w, out, add)
  elseif state == "ready" and r.ai then
    ready_ai_rows(r, out, add)
  elseif state == "ready" then
    ready_rows(r, out)
  elseif state == "ci" then
    out.text(string.format(
      'When CI is green the block moves to done today as "✓ fixed". %s',
      r.draft and "#" .. r.number .. " is a draft, so it stops there and doesn't merge." or "It never merges by itself."
    ))
  end
  if r.detail then out.text(r.detail, "PrOrange") end
  if r.note then out.text(r.note, "PrOrange") end
end

local function elapsed(ai) return ui.clock((ai.ended or os.time()) - (ai.started or os.time())) end

local function bar(done, total, w)
  local filled = total > 0 and math.floor(w * done / total) or 0
  return { { string.rep("━", filled), "PrYellow" }, { string.rep("━", w - filled), "PrFaint" }, { " " } }
end

local function lane_head(m, w)
  local ai = m.ai
  local phase = ai.phase
  local total, resolved = ai.total or #(ai.files or {}), ai.resolved or 0
  local plan_tag = ai.plan and string.format(" · plan %d/%d", ai.group or #ai.plan.groups, #ai.plan.groups) or ""
  local icon, hl, extra, right = "◆", "PrYellow", "", { { elapsed(ai), "PrMuted" } }
  local progress = { { string.format("%d/%d  ", resolved, total), "PrMuted" }, { elapsed(ai), "PrMuted" } }
  if phase == "queued" then
    icon, hl, extra, right = "○", "PrPending", "  queued, starts next", { { "0/" .. #ai.files, "PrMuted" } }
  elseif phase == "planning" or phase == "checking" then
    extra = " · " .. phase
  elseif phase == "running" then
    extra = ai.plan and plan_tag or string.format(" · no plan, %d files", total)
    right = vim.list_extend(bar(resolved, total, 14), progress)
  elseif phase == "failed" then
    icon, hl, extra, right = "✗", "PrRed", " · " .. (ai.why or ""), {}
  elseif phase == "gave_up" then
    local gave = #vim.tbl_filter(function(f) return (m.marks[f.path] or {}).gave_up end, unresolved(m))
    icon, hl, extra, right = "✗", "PrRed", plan_tag .. " gave up on " .. gave, progress
  elseif phase == "paused" then
    icon, hl, extra, right = "⏱", "PrYellow", " " .. (ai.why or "paused"), progress
  elseif phase == "stopped" then
    icon, hl, extra, right = "✗", "PrRed", string.format(" · plan step %s stopped  needs you", (ai.stopped or {}).group or "?"), { { elapsed(ai), "PrMuted" } }
  end
  local used = ui.width(icon .. " #" .. m.number .. " " .. extra .. "  ")
  for _, seg in ipairs(right) do used = used + ui.width(seg[1]) end
  return ui.fit_line(vim.list_extend({
    { icon, hl }, { " " }, { "#" .. m.number, "PrTitle" }, { " " }, { ui.fit(m.title or "", math.max(8, w - used - 1)) }, { extra, "PrSoft" }, { "  " },
  }, right), w)
end

local function lane_lines(m, w, add)
  local ai, target = m.ai, { merge = m }
  local function row(segs, t) add(indented(segs), t or target) end
  local function steps(status)
    for i, group in ipairs(ai.plan.groups) do
      local done, total = pr_ai.group_progress(m, i)
      if total > 0 then
        local icon, hl, state = status(i, done, total)
        row({ { icon, hl }, { " " .. i .. "  " .. total .. " · " .. group.title .. "  " }, { state, "PrMuted" } })
      end
    end
  end
  local phase = ai.phase
  add(lane_head(m, w), target)
  if phase == "queued" or phase == "planning" or phase == "running" or phase == "checking" then
    if ai.expanded ~= false and ai.plan and phase ~= "planning" then
      steps(function(i, done, total)
        if done == total then return "✓", "PrGreen", "done" end
        if i == ai.group then return "◆", "PrYellow", done .. "/" .. total .. (ai.current and " · " .. vim.fs.basename(ai.current) or "") end
        return "○", "PrPending", "waiting"
      end)
    elseif ai.current then
      row({ { "editing " .. ai.current, "PrSoft" } })
    end
    if ai.last then row({ { "claude ", "PrMuted" }, { ai.last, "PrMuted" } }) end
  elseif phase == "gave_up" then
    for _, f in ipairs(unresolved(m)) do
      local mark = m.marks[f.path] or {}
      if mark.gave_up then
        local tail = ""
        if mark.suggestion then
          tail = " · s adds that as a step"
        elseif mark.gave_up ~= "markers left" then
          tail = " · markers left"
        end
        row({ { "✗ ", "PrRed" }, { f.path .. ' "' .. mark.gave_up .. '"' }, { tail, "PrMuted" } }, { merge = m, file = f })
      end
    end
    row({ { string.format("◆ %d kept · nothing pushed", #m.files - #unresolved(m)), "PrMuted" } })
  elseif phase == "paused" then
    row({ { string.format("progress kept · c continue %d · enter finish by hand · x back to %s", #unresolved(m), m.orig:sub(1, 7)), "PrMuted" } })
  elseif phase == "stopped" then
    local stopped = ai.stopped or {}
    if ai.plan then
      steps(function(i)
        if i < (stopped.group or 0) then return "✓", "PrGreen", "done" end
        if i == stopped.group then return "✗", "PrRed", (stopped.reason or "") .. " stopped" end
        return "○", "PrPending", "not started"
      end)
    end
    if stopped.suggestion then row({ { 'claude "' .. stopped.suggestion .. '" s applies that and continues.', "PrMuted" } }) end
  elseif phase == "failed" then
    row({ { "x goes back to " .. m.orig:sub(1, 7), "PrMuted" } })
  end
end

local function render(focus)
  if not view or not vim.api.nvim_win_is_valid(view.win) then return end
  if not vim.api.nvim_buf_is_valid(view.buf) or vim.api.nvim_win_get_buf(view.win) ~= view.buf then return close() end
  review.unseen = nil
  local w = vim.api.nvim_win_get_width(view.win)
  local lines, rows, first, hls = {}, {}, {}, {}
  local function add(segs, target, line_hl)
    lines[#lines + 1] = segs
    rows[#lines] = target
    hls[#lines] = line_hl
  end

  local running, agents, done = {}, {}, {}
  for _, m in ipairs(review.merges) do table.insert(m.finished and done or pr_ai.lane(m) and agents or running, m) end
  table.sort(done, function(a, b) return a.finished > b.finished end)
  local at = view.rows[vim.api.nvim_win_get_cursor(view.win)[1]]
  hover = at and at.file and at.file.path

  if #running + #agents + #done == 0 then
    add({ { "No merges yet. alt-m in <leader>gP starts one.", "PrMuted" } })
  else
    local active = "done"
    if #running > 0 then
      active = "running"
    elseif #agents > 0 then
      active = "agents"
    end
    local chips = { { " running " .. #running .. " ", active == "running" and "PrChip" or "PrSoft" } }
    if #agents > 0 then vim.list_extend(chips, { { "  " }, { " agents " .. #agents .. " ", active == "agents" and "PrChip" or "PrSoft" } }) end
    vim.list_extend(chips, { { "  " }, { " done today " .. #done .. " ", active == "done" and "PrChip" or "PrSoft" } })
    add(chips)
    add({})
  end

  local function record(m)
    local target = { merge = m }
    first[m] = #lines + 1
    if pr_ai.lane(m) then
      lane_lines(m, w, add)
      return add({})
    end
    add(head_line(m, w), target)
    if m.kind == "fix" and not m.finished then
      fix_lines(m, w, add)
    elseif m.kind == "fix" then
      if expanded_of(m) and m.note then add(indented({ { m.note, "PrMuted" } }), target) end
    elseif not m.finished then
      add(chips_line(m), target)
      local body = m.state == "asking" and asking_lines(m) or wrapped(m.detail or "", "PrMuted", w)
      for _, segs in ipairs(body) do add(segs, target) end
    elseif expanded_of(m) then
      if m.state == "merged" then
        add(indented({ { m.summary or "", "PrDim" } }), target)
        local fallout = m.fallout
        if fallout == nil then
          add(indented({ { "checking other PRs…", "PrMuted" } }), target)
        elseif fallout == false then
          add(indented({ { "could not re-check other PRs", "PrMuted" } }), target)
        elseif #fallout == 0 then
          add(indented({ { "other PRs OK", "PrMuted" } }), target)
        else
          add(indented({ { "changed for other PRs", "PrMuted" } }), target)
          for _, item in ipairs(fallout) do
            local item_target = { merge = m, item = item }
            local attempt = fix.latest(m.dir, item.number, m.finished)
            local icon, icon_hl, label = item.icon, item.hl, item.text
            if attempt and not attempt.finished then
              icon, icon_hl, label = "●", "PrYellow", "fixing ↑"
              if attempt.state == "ci" then icon, icon_hl, label = "✓", "PrGreen", "conflict fixed · CI running ↑" end
              attempt = true
            elseif attempt and attempt.state == "fixed" then
              icon, icon_hl, label = "✓", "PrGreen", "conflict fixed"
              attempt = true
            else
              attempt = false
            end
            local row = {
              { "    " }, { tostring(item.number), "PrYellow" }, { "  " }, { icon, icon_hl }, { " " .. label }, { item.note or "", "PrMuted" },
            }
            local probe = not attempt and item.probe
            if probe then
              local used = ui.width("    " .. item.number .. "  " .. icon .. " " .. label)
              row[#row + 1] = { string.rep(" ", math.max(2, w - used - ui.width(probe.note) - 2)) }
              row[#row + 1] = { probe.note, probe.hard == 0 and "PrGreen" or "PrYellow" }
            end
            add(row, item_target)
            if probe then
              add({ { "          " .. probe.sentence, "PrMuted" } }, item_target)
            elseif item.fix and not attempt then
              add({ { "          " .. item.fix, "PrCode" } }, item_target)
            end
          end
        end
      else
        add(indented({ { "✗ " .. (m.reason or ""), "PrGateBlocked" } }), target)
        if m.note then add(indented({ { m.note, "PrMuted" } }), target) end
        if m.fix and not m.draft and not m.conflict then
          add(indented({ { "fix  ", "PrMuted" }, { m.fix, "PrCode" } }), target)
        end
      end
    end
    add({})
  end

  for _, m in ipairs(running) do record(m) end
  if #agents > 0 then
    local label, tail = "agents ", " " .. pr_ai.max_agents .. " at a time"
    add({ { label, "PrMuted" }, { string.rep("─", math.max(1, w - ui.width(label .. tail))), "PrFaint" }, { tail, "PrMuted" } })
    for _, m in ipairs(agents) do record(m) end
  end
  if #done > 0 then
    add({ { "done today ", "PrMuted" }, { string.rep("─", math.max(1, w - ui.width("done today "))), "PrFaint" } })
    for _, m in ipairs(done) do record(m) end
  end

  while #lines > 0 and #lines[#lines] == 0 do lines[#lines] = nil end
  local cursor = vim.api.nvim_win_get_cursor(view.win)
  local old = view.rows[cursor[1]]
  local offset = old and view.first[old.merge] and cursor[1] - view.first[old.merge] or 0
  view.rows, view.first = rows, first
  ui.to_buf(view.buf, lines, hls)

  local row = math.min(cursor[1], math.max(1, #lines))
  if focus and first[focus] then
    row = first[focus]
  elseif old and old.item then
    local found
    for r, target in pairs(rows) do
      if target.item == old.item and (not found or r < found) then found = r end
    end
    row = found or first[old.merge] or row
  elseif old and first[old.merge] then
    row = first[old.merge] + offset
    while row > first[old.merge] and not (rows[row] and rows[row].merge == old.merge) do row = row - 1 end
  end
  pcall(vim.api.nvim_win_set_cursor, view.win, { row, focus and 0 or cursor[2] })
  M.update_footer()
  vim.cmd("redrawstatus")
end

local function ai_footer(r, t, add)
  local ai, orig = r.ai, r.orig:sub(1, 7)
  local phase = ai.phase
  if r.state == "plan" then
    add("y", "run in background")
    add("s", "change strategy")
    add("enter", "files")
    add("x", "cancel")
  elseif r.state == "claude" then
    if phase ~= "failed" then add("enter", "expand") end
    add("t", "transcript")
    add("x", phase == "failed" and "undo" or "stop + undo")
  elseif r.state == "ready" then
    add("p", "push")
    add("d", "diff vs your branch")
    add("]q", "step through files")
    add("t", "transcript")
    add("x", "undo, back to " .. orig)
  elseif phase == "gave_up" then
    add("enter", "open at markers")
    add("c", "retry / continue")
    add("s", "change strategy")
    add("t", "transcript")
    add("x", "undo")
  elseif phase == "paused" then
    add("c", "continue " .. #unresolved(r))
    add("enter", "finish by hand")
    add("t", "transcript")
    add("x", "back to " .. orig)
  elseif phase == "stopped" then
    add("s", "change strategy + continue")
    add("t", "transcript")
    add("x", "undo")
  elseif phase == "review" or phase == "done" then
    add("a", "accept guess")
    add("e", "edit")
    add("]q", "next unsure")
    add("t", "transcript at file")
    add("x", "undo")
  else
    return false
  end
  return true
end

local function fix_footer(t, add)
  local r = t.merge
  local state, orig = r.state, r.orig and r.orig:sub(1, 7)
  if r.awaiting_p and state == "resolving" then
    add("p", "commit and push")
    add("d", "diff vs your branch")
  end
  if r.ai and ai_footer(r, t, add) then return end
  if state == "resolving" and not r.stacked and #unresolved(r) > 0 then
    add("c", t.file and t.file.status == "real" and "Claude does this file" or "let Claude do the " .. #unresolved(r))
  end
  if t.file and t.file.status == "ready" then
    add("a", "accept proposal")
    add("e", "edit the file instead")
  elseif t.file and t.file.kind == "content" then
    add("enter", "open at conflict")
  elseif state == "resolving" and vim.iter(r.files):any(function(f) return f.status == "ready" end) then
    add("a", "accept proposal")
  end
  if state == "ready" then
    if r.stacked then add("P", "force-push with lease") else add("p", "push") end
    add("d", r.stacked and "diff" or "diff vs your branch")
    add("x", "undo, back to " .. orig)
  elseif state == "ci" then
    add("^b", "CI in browser")
    add("enter", "open PR")
  elseif state == "dirty" then
    add("s", "stash + fix")
    add("y", "copy commands")
    add("x", "abort")
  elseif state == "no_worktree" then
    add("w", "create worktree")
    add("y", "copy commands")
    add("x", "abort")
  elseif state == "paused" then
    add("enter", "continue")
    add("x", "back to " .. orig)
  elseif state == "failed" then
    add("f", "fetch and redo")
    add("enter", "expand")
  elseif r.finished then
    add("enter", "expand")
  elseif state ~= "pushing" then
    add("x", "abort")
  end
end

local function target_keys(t)
  if not t then return { { "q", "close" } } end
  local m, keys = t.merge, {}
  local function add(key, label) keys[#keys + 1] = { key, label } end
  if m.kind == "fix" then
    fix_footer(t, add)
    local keeps = not m.finished and (m.state == "fetching" or m.state == "merging" or m.state == "rebasing" or m.state == "claude")
    add("q", keeps and "close, keeps running" or "close")
    return keys
  end
  if t.item then
    if t.item.icon == "✗" or t.item.icon == "↳" then
      add("f", "fix")
      if t.item.probe then add("d", "preview fix") end
      if t.item.fix then add("y", "copy commands") end
    else
      if t.item.fix then add("y", "copy fix") end
      add("alt-m", "merge this one")
    end
    add("enter", "open PR")
  elseif m.state == "asking" then
    add("u", "update")
    add("m", "merge as tested")
    add("x", "cancel")
  elseif m.state == "squashing" then
    if not m.squash_sent then add("x", "stop before squash") end
  elseif m.state == "merged" then
    add("enter", "expand")
    add("^b", "browser")
  elseif m.state == "failed" then
    if m.log_url then add("l", "failed log") end
    if m.fix then add("y", "copy fix") end
    add("r", "retry")
    add("enter", "expand")
  elseif m.state == "refused" then
    if m.draft then add("R", "mark ready + merge") end
    if m.conflict then add("f", "fix") end
    if m.log_url then add("l", "failed log") end
    if m.fix then add("y", "copy fix") end
    add("r", "retry")
  else
    add("x", "cancel")
    add("^b", "browser")
  end
  local running_only = not m.finished and m.state ~= "asking" and m.state ~= "squashing" and not t.item
  add("q", running_only and "close, keeps running" or "close")
  return keys
end

local function footer_keys(t)
  local keys = target_keys(t)
  table.insert(keys, #keys, { "⌫", "PRs" })
  return keys
end

function M.update_footer()
  if not view or not vim.api.nvim_win_is_valid(view.win) then return end
  local row = vim.api.nvim_win_get_cursor(view.win)[1]
  vim.api.nvim_win_set_config(view.win, { footer = ui.footer(footer_keys(view.rows[row])), footer_pos = "center" })
end

local function any_running()
  return vim.iter(review.merges):any(function(m) return not m.finished end)
end

local function browse(m, number)
  vim.fn.jobstart({ "gh", "pr", "view", tostring(number), "--web" }, { cwd = m.dir, detach = true })
end

close = function()
  if view and vim.api.nvim_win_is_valid(view.win) then vim.api.nvim_win_close(view.win, true) end
end
M.close = close

function M.open_file(r, f)
  close()
  vim.cmd("edit " .. vim.fn.fnameescape(r.path .. "/" .. f.path))
  vim.cmd("normal! gg")
  vim.fn.search("^<<<<<<<\\+ ", "W")
  vim.cmd("normal! zz")
end

-- Same renderer as lazygit's pager (delta) when it is installed; plain diff otherwise.
local function preview_float(text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local w, h = math.floor(vim.o.columns * 0.8), math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = w, height = h, row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    style = "minimal", border = "rounded", title = { { " fix preview ", "PrOrangeBold" } }, title_pos = "center",
  })
  if text ~= "" and vim.fn.executable("delta") == 1 then
    local file = vim.fn.tempname()
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), file)
    vim.fn.jobstart({ "sh", "-c", "delta --width=" .. (w - 2) .. ' --paging=always < "$0"; rm -f "$0"', file }, {
      term = true,
      env = { DELTA_PAGER = "less -R" },
      on_exit = function() pcall(vim.api.nvim_win_close, win, true) end,
    })
    return vim.cmd.startinsert()
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text ~= "" and text or "no changes", "\n", { plain = true }))
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, "<cmd>close<cr>", { buffer = buf, nowait = true })
  end
end

local function preview(t)
  local r = t.merge
  if t.item and t.item.probe then
    local parts = {}
    for _, f in ipairs(t.item.probe.files) do
      if f.res then
        parts[#parts + 1] = string.format("--- a/%s\n+++ b/%s\n%s", f.path, f.path, vim.diff(f.ours, f.res.result))
      end
    end
    return preview_float(table.concat(parts, "\n"))
  end
  if r.kind == "fix" and r.awaiting_p and r.state == "resolving" and r.path then
    local out = vim.system({ "git", "diff", "--cached", r.orig }, { cwd = r.path, text = true }):wait()
    return preview_float(out.stdout or "")
  end
  if r.kind == "fix" and r.ai and r.state == "resolving" and r.path then return preview_float(pr_ai.diff_text(r)) end
  if r.kind == "fix" and (r.state == "ready" or r.state == "fixed") and r.path then
    local out = vim.system({ "git", "diff", r.orig, "HEAD" }, { cwd = r.path, text = true }):wait()
    preview_float(out.stdout or "")
  end
end

local function setup_keys(buf)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, function()
      local t = view.rows[vim.api.nvim_win_get_cursor(view.win)[1]]
      if t then fn(t) end
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<BS>", function()
    close()
    review.pick()
  end, { buffer = buf, nowait = true })
  map("u", function(t) review.answer_merge(t.merge, "update") end)
  map("m", function(t) review.answer_merge(t.merge, "tested") end)
  map("x", function(t)
    local m = t.merge
    if m.kind == "fix" and m.state == "plan" then return pr_ai.decline(m) end
    if m.kind == "fix" and m.state == "claude" then return pr_ai.stop(m) end
    if m.kind == "fix" then return fix.abort(m) end
    review.cancel_merge(m)
  end)
  map("c", function(t)
    local r = t.merge
    if r.kind == "fix" then
      if r.state == "resolving" then pr_ai.start(r, t.file and t.file.status == "real" and not r.ai and t.file or nil) end
    elseif t.item and (t.item.icon == "✗" or t.item.icon == "↳") and t.item.branch then
      render(pr_ai.start_item(r, t.item))
    elseif r.conflict and r.pr then
      render(pr_ai.start_item({ dir = r.dir }, { number = r.number, title = r.title, branch = r.pr.headRefName, base = r.pr.baseRefName, fix = r.fix }))
    end
  end)
  map("t", function(t)
    if t.merge.ai then pr_ai.transcript(t.merge, t.file and t.file.path) end
  end)
  map("]q", function(t)
    if t.merge.ai then pr_ai.quickfix(t.merge) end
  end)
  map("f", function(t)
    local r = t.merge
    if t.item and (t.item.icon == "✗" or t.item.icon == "↳") and t.item.branch then return render(fix.start(r, t.item)) end
    if r.kind == "fix" and r.state == "failed" then return render(fix.redo(r)) end
    if r.conflict and r.pr then
      render(fix.start({ dir = r.dir }, {
        number = r.number, title = r.title, branch = r.pr.headRefName, base = r.pr.baseRefName, fix = r.fix,
      }))
    end
  end)
  map("d", preview)
  map("a", function(t)
    local m = t.merge
    if m.kind ~= "fix" then return end
    if t.file and m.marks and m.marks[t.file.path] and m.marks[t.file.path].unsure then return pr_ai.accept(m, t.file.path) end
    fix.accept(m, t.file)
  end)
  map("e", function(t)
    if t.file then M.open_file(t.merge, t.file) end
  end)
  map("s", function(t)
    local m = t.merge
    if m.kind ~= "fix" then return end
    if pr_ai.wants_strategy(m) then return pr_ai.strategy(m) end
    fix.stash(m)
  end)
  map("w", function(t)
    if t.merge.kind == "fix" then fix.worktree(t.merge) end
  end)
  map("p", function(t)
    if t.merge.kind == "fix" then fix.push(t.merge, false) end
  end)
  map("P", function(t)
    if t.merge.kind == "fix" then fix.push(t.merge, true) end
  end)
  map("<CR>", function(t)
    local r = t.merge
    if t.group then return pr_ai.quickfix(r, t.group) end
    if t.paths then return pr_ai.quickfix(r, t.paths) end
    if t.file and t.file.kind == "content" then return M.open_file(r, t.file) end
    if r.kind == "fix" and r.ai and r.ai.phase == "paused" and r.state == "resolving" then
      local first = unresolved(r)[1]
      return first and M.open_file(r, first)
    end
    if pr_ai.lane(r) then
      r.ai.expanded = not (r.ai.expanded ~= false and r.ai.plan ~= nil)
      return render()
    end
    if r.kind == "fix" and r.state == "paused" then return fix.resume(r) end
    if t.item or (r.kind == "fix" and not r.finished) then return browse(r, t.item and t.item.number or r.number) end
    if not r.finished then return end
    t.merge.expanded = not expanded_of(t.merge)
    render()
  end)
  map("<C-b>", function(t)
    local m = t.merge
    if m.kind == "fix" and m.state == "ci" then
      return vim.fn.jobstart({ "gh", "pr", "checks", tostring(m.number), "--web" }, { cwd = m.dir, detach = true })
    end
    browse(m, t.item and t.item.number or m.number)
  end)
  map("y", function(t)
    if t.merge.state == "plan" then return pr_ai.run(t.merge) end
    if t.merge.kind == "fix" or t.item then return fix.commands(t) end
    ui.copy_fix(t.merge.fix)
  end)
  map("l", function(t)
    local m = t.merge
    if m.log_url then return vim.ui.open(m.log_url) end
    vim.fn.jobstart({ "gh", "pr", "checks", tostring(m.number), "--web" }, { cwd = m.dir, detach = true })
  end)
  map("r", function(t)
    if t.merge.kind ~= "fix" and (t.merge.state == "failed" or t.merge.state == "refused") then render(review.retry_merge(t.merge)) end
  end)
  map("R", function(t)
    if t.merge.kind ~= "fix" and t.merge.draft then review.ready_and_merge(t.merge, render) end
  end)
  map("<M-m>", function(t)
    if t.item then render(review.merge_pr(t.merge.dir, t.item.number)) end
  end)
end

function M.open(focus)
  review.unseen = nil
  ui.setup_hl()
  fix.refresh(vim.fs.root(0, ".git") or vim.uv.cwd())
  if view and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_win_get_buf(view.win) == view.buf then
    vim.api.nvim_set_current_win(view.win)
    return render(focus)
  end
  close()

  local w, h = math.floor(vim.o.columns * 0.76), math.floor(vim.o.lines * 0.8)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h - 2) / 2),
    col = math.floor((vim.o.columns - w - 2) / 2),
    style = "minimal",
    border = "rounded",
    title = { { " merges ", "PrOrangeBold" } },
    title_pos = "center",
    footer = ui.footer(footer_keys(nil)),
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  view = { win = win, buf = buf, rows = {}, first = {} }

  local group = vim.api.nvim_create_augroup("PrMerges", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "PrMergesChanged", callback = function() vim.schedule(render) end })
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = M.update_footer })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function() vim.schedule(close) end })
  local timer = vim.uv.new_timer()
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if any_running() then render() end
  end))
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      timer:stop()
      timer:close()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      if view and view.win == win then view = nil end
    end,
  })

  setup_keys(buf)
  render(focus)
end

local function running_records()
  return vim.tbl_filter(function(m) return not m.finished end, review.merges)
end

local WAITING = { resolving = true, dirty = true, no_worktree = true, paused = true }

local function waiting_records()
  return vim.tbl_filter(function(m)
    return m.kind == "fix" and WAITING[m.state] or m.state == "asking"
  end, running_records())
end

local function fix_status(r)
  if r.state == "ci" then return string.format("fix #%d %s %s", r.number, ci_label(r), ui.clock(os.time() - r.started)) end
  local label = { ready = "ready to push", resolving = "needs you", pushing = "pushing", merging = "merging", rebasing = "rebasing" }
  return string.format("fix #%d %s", r.number, label[r.state] or "fetching")
end

function M.statusline()
  local running = running_records()
  local ai_text = pr_ai.status_text(running)
  if ai_text then return ai_text end
  if #running > 0 then
    local text = " " .. #running
    local waiting = waiting_records()
    if #waiting > 1 then return text .. " · " .. #waiting .. " need you" end
    if #waiting == 1 then
      local only = waiting[1]
      return text .. " · " .. (only.kind == "fix" and "fix #" or "#") .. only.number .. " needs you"
    end
    local ready = vim.iter(running):find(function(m) return m.kind == "fix" and m.state == "ready" end)
    if ready then return text .. " · " .. fix_status(ready) end
    local newest = running[1]
    if newest.kind == "fix" then return text .. " · " .. fix_status(newest) end
    if newest.state == "ci" then
      return string.format("%s · #%d %s %s", text, newest.number, ci_label(newest), ui.clock(os.time() - newest.started))
    end
    return text
  end
  local m = review.unseen
  if not m or m.state == "aborted" then return "" end
  if m.kind == "fix" then return m.state == "fixed" and "✓ fix #" .. m.number .. " fixed" or "✗ fix #" .. m.number .. " not fixed" end
  return m.state == "merged" and "✓ #" .. m.number .. " merged" or "✗ #" .. m.number .. " not merged"
end

function M.statusline_color()
  local running = running_records()
  local ai_text, attention = pr_ai.status_text(running)
  if #running > 0 then
    local color = { fg = "#e9b143", bg = "#3a3420" }
    local bold = attention
    if not ai_text then bold = #waiting_records() > 0 end
    if bold then color.gui = "bold" end
    return color
  end
  local m = review.unseen
  if m and (m.state == "merged" or m.state == "fixed") then return { fg = "#b0b846", bg = "#34381b" } end
  return { fg = "#f2594b", bg = "#3c2a1e" }
end

vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("PrMergesStatus", { clear = true }),
  pattern = "PrMergesChanged",
  callback = function() vim.schedule(function() vim.cmd("redrawstatus") end) end,
})

return M
