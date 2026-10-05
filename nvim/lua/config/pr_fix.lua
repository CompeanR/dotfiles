local M = {}

local review = require("config.review_pr")
local core = review.core
local set, finish, guard, changed = core.set, core.finish, core.guard, core.changed

M.STEPS = {
  merge = { "clean", "fetch", "merge", "resolve", "push", "ci" },
  stacked = { "clean", "fetch", "rebase", "push", "ci" },
  ai = { "merge", "plan", "run", "review", "push", "ci" },
}

local NOPROMPT = { GIT_TERMINAL_PROMPT = "0" }
local LITERAL = { GIT_LITERAL_PATHSPECS = "1" }
local EDITOR = { GIT_EDITOR = "true" }

local plural = core.plural

local function git_error_line(text)
  local lines = vim.tbl_map(function(line) return vim.trim(line:match("[^\r]*$")) end, vim.split(vim.trim(text), "\n"))
  local failure = vim.iter(lines):find(function(line) return line:match("^fatal:") or line:match("^error:") end)
  local other = vim.iter(lines):find(function(line) return line ~= "" and not line:match("^hint:") end)
  return failure or other or lines[1] or ""
end

local function read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function exists(path) return vim.uv.fs_stat(path) ~= nil end

local function raw(args, dir, on_done)
  vim.system(args, { cwd = dir }, function(result)
    vim.schedule(function() on_done(result.code == 0, result.stdout or "") end)
  end)
end

local function common_key(common) return vim.fs.basename(common) == ".git" and vim.fs.dirname(common) or common end

local keys = {}

local function repo_key(dir)
  if not keys[dir] then
    local out = vim.system({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, { cwd = dir, text = true }):wait()
    local common = vim.trim(out.stdout or "")
    keys[dir] = out.code == 0 and common ~= "" and common_key(common) or dir
  end
  return keys[dir]
end

local function find_fix(dir, number, accept)
  local key = repo_key(dir)
  return vim.iter(review.merges):find(function(r)
    return r.kind == "fix" and r.number == number and repo_key(r.dir) == key and accept(r)
  end)
end

local function unfinished(r) return not r.finished end

-- Resolver: a three-way line merge that only auto-resolves when no base line is
-- changed by both sides. Git conflicts on neighbouring edits; this does not.

local function split(text)
  if text == "" then return {}, false end
  local eol = text:sub(-1) == "\n"
  return vim.split(eol and text:sub(1, -2) or text, "\n", { plain = true }), eol
end

local function joined(lines) return #lines > 0 and table.concat(lines, "\n") .. "\n" or "" end

local function edits_of(base, side_lines, side)
  local out = {}
  local hunks = vim.diff(joined(base), joined(side_lines), { result_type = "indices", algorithm = "histogram" })
  for _, hunk in ipairs(hunks) do
    local sa, ca, sb, cb = unpack(hunk)
    local from = ca == 0 and sa or sa - 1
    out[#out + 1] = {
      from = from,
      to = from + ca,
      lines = vim.list_slice(side_lines, sb, sb + cb - 1),
      removed = vim.list_slice(base, from + 1, from + ca),
      side = side,
      at = math.max(sb, 1),
    }
  end
  return out
end

local function insertion(e) return e.from == e.to end

local function same(a, b) return a.from == b.from and a.to == b.to and vim.deep_equal(a.lines, b.lines) end

local function clashes(a, b)
  if same(a, b) then return false end
  if math.max(a.from, b.from) < math.min(a.to, b.to) then return true end
  if insertion(a) and insertion(b) then return a.from == b.from end
  if insertion(a) then return b.from < a.from and a.from < b.to end
  if insertion(b) then return a.from < b.from and b.from < a.to end
  return false
end

local function order(a, b)
  if a.from ~= b.from then return a.from < b.from end
  return insertion(a) and not insertion(b)
end

local function apply(base, from, to, edits)
  local out, cursor = {}, from
  for _, e in ipairs(edits) do
    vim.list_extend(out, base, cursor + 1, e.from)
    vim.list_extend(out, e.lines)
    cursor = math.max(cursor, e.to)
  end
  vim.list_extend(out, base, cursor + 1, to)
  return out
end

local function of_side(edits, side)
  return vim.tbl_filter(function(e) return e.side == side or e.side == "both" end, edits)
end

function M.resolve(base_text, ours_text, theirs_text, labels)
  labels = labels or { ours = "ours", theirs = "theirs" }
  local base, base_eol = split(base_text)
  local ours, ours_eol = split(ours_text)
  local theirs, theirs_eol = split(theirs_text)
  local eol = ours_eol
  if ours_eol == base_eol then eol = theirs_eol end

  local edits = edits_of(base, ours, "ours")
  for _, e in ipairs(edits_of(base, theirs, "theirs")) do
    local twin = vim.iter(edits):find(function(o) return same(o, e) end)
    if twin then
      twin.side = "both"
    else
      edits[#edits + 1] = e
    end
  end
  table.sort(edits, order)

  local groups = {}
  for _, e in ipairs(edits) do
    local group = groups[#groups]
    if group and e.from <= group.to then
      group.edits[#group.edits + 1] = e
      group.to = math.max(group.to, e.to)
    else
      groups[#groups + 1] = { from = e.from, to = e.to, edits = { e } }
    end
  end

  local out, cursor, hard, clusters = {}, 0, 0, {}
  for _, group in ipairs(groups) do
    vim.list_extend(out, base, cursor + 1, group.from)
    cursor = group.to
    local conflict, has_ours, has_theirs = false, false, false
    for i, a in ipairs(group.edits) do
      has_ours = has_ours or a.side == "ours"
      has_theirs = has_theirs or a.side == "theirs"
      for j = i + 1, #group.edits do
        local b = group.edits[j]
        if a.side ~= b.side and clashes(a, b) then conflict = true end
      end
    end
    local mine = apply(base, group.from, group.to, of_side(group.edits, "ours"))
    local other = apply(base, group.from, group.to, of_side(group.edits, "theirs"))
    if conflict then
      hard = hard + 1
      vim.list_extend(out, { "<<<<<<< " .. labels.ours })
      vim.list_extend(out, mine)
      vim.list_extend(out, { "=======" })
      vim.list_extend(out, other)
      vim.list_extend(out, { ">>>>>>> " .. labels.theirs })
    else
      vim.list_extend(out, apply(base, group.from, group.to, group.edits))
    end
    if has_ours and has_theirs then
      local first = vim.iter(group.edits):find(function(e) return e.side == "ours" end)
      clusters[#clusters + 1] = {
        from = group.from,
        to = group.to,
        edits = group.edits,
        hard = conflict,
        before = base[group.from],
        after = base[group.to + 1],
        ours = mine,
        theirs = other,
        pr_line = first.at,
      }
    end
  end
  vim.list_extend(out, base, cursor + 1, #base)
  return { hard = hard, clusters = clusters, result = table.concat(out, "\n") .. (eol and #out > 0 and "\n" or "") }
end

function M.label(line) return line:match('"([^"]+)"') or vim.trim(line) end

-- Conflicts: parse git's unmerged records and classify every file

local function parse_stages(text)
  local files, by_path = {}, {}
  for _, record in ipairs(vim.split(text, "\0", { plain = true })) do
    local oid, stage, path = record:match("^%d+ (%x+) (%d)\t(.+)$")
    if path then
      local file = by_path[path]
      if not file then
        file = { path = path, stages = {} }
        by_path[path] = file
        files[#files + 1] = file
      end
      file.stages[tonumber(stage)] = oid
    end
  end
  return files
end

local function read_blobs(dir, oids, on_done)
  local texts, pending = {}, 0
  for i = 1, 3 do
    if oids[i] then
      pending = pending + 1
      raw({ "git", "cat-file", "blob", oids[i] }, dir, function(_, out)
        texts[i] = out
        pending = pending - 1
        if pending == 0 then on_done(texts) end
      end)
    else
      texts[i] = ""
    end
  end
  if pending == 0 then on_done(texts) end
end

local function classify(dir, records, pr_stage, labels, on_done)
  local files, pending = {}, #records
  if pending == 0 then return on_done(files) end
  for i, record in ipairs(records) do
    local mine, other = record.stages[pr_stage], record.stages[5 - pr_stage]
    local file = { path = record.path, kind = "content", status = "real", markers = 0 }
    files[i] = file
    local function done()
      pending = pending - 1
      if pending == 0 then on_done(files) end
    end
    if not mine or not other then
      file.kind = "other"
      file.why = mine and "deleted on " .. labels.theirs .. ", changed in " .. labels.ours
        or "deleted in " .. labels.ours .. ", changed on " .. labels.theirs
      done()
    else
      read_blobs(dir, { record.stages[1], mine, other }, function(texts)
        if vim.iter(texts):any(function(text) return text:find("\0", 1, true) end) then
          file.kind, file.why = "other", "binary file"
        else
          file.res = M.resolve(texts[1], texts[2], texts[3], labels)
          file.ours = texts[2]
          file.easy = file.res.hard == 0
          file.status = file.easy and "ready" or "real"
        end
        done()
      end)
    end
  end
end

local function needs_you(file) return file.kind == "other" or not file.easy end

-- Probe: try the merge in memory and describe what git cannot do

local function side_of(edits, master)
  local removed, added = 0, 0
  for _, e in ipairs(edits) do
    if (e.side == "theirs") == master then
      removed = removed + e.to - e.from
      added = added + #e.lines
    end
  end
  local verb = "changed"
  if added == 0 then
    verb = "removed"
  elseif removed == 0 then
    verb = "added"
  end
  return verb, math.max(removed, added)
end

local function sentence_of(files, from, number)
  local need = vim.tbl_filter(needs_you, files)
  if #need == 0 then
    if #files > 1 then return "Git can't merge them, but every fix is clear." end
    local cluster = files[1].res.clusters[1]
    if not cluster then return "Git can't merge it, but the fix is clear." end
    local master_verb, master_count = side_of(cluster.edits, true)
    local pr_verb, pr_count = side_of(cluster.edits, false)
    return string.format(
      "%s: #%d %s %s next to %s #%d %s. Git can't merge it, but the fix is clear.",
      files[1].path, from, master_verb, master_count == 1 and "a line" or master_count .. " lines",
      pr_count == 1 and "one" or pr_count .. " lines", number, pr_verb
    )
  end
  local first = need[1]
  local text = first.path .. ": " .. (first.why or "")
  if first.kind == "content" then
    local hard = vim.iter(first.res.clusters):find(function(c) return c.hard end)
    text = first.path .. ": both changed line " .. (hard and hard.pr_line or 1)
  end
  return text .. (#need > 1 and " +" .. (#need - 1) .. " more" or "")
end

local function annotate_item(item, files, from)
  local need = #vim.tbl_filter(needs_you, files)
  local note = plural(#files, "file") .. " · "
  note = note .. (need == 0 and "fix ready" or need .. (need == 1 and " needs you" or " need you"))
  item.probe = { files = files, hard = need, note = note, sentence = sentence_of(files, from, item.number) }
end

local function probe_item(m, item)
  local args = { "git", "merge-tree", "--write-tree", "-z", "--no-messages", "origin/" .. item.branch, "origin/" .. item.base }
  core.system(args, m.dir, function(_, out, _, code)
    if code == 0 then
      item.probe = { files = {}, hard = 0, note = "merges cleanly", sentence = "Merges cleanly now." }
      return changed()
    end
    if code ~= 1 then return end
    local labels = { ours = "#" .. item.number, theirs = item.base }
    classify(m.dir, parse_stages(out), 2, labels, function(files)
      annotate_item(item, files, m.number)
      changed()
    end)
  end)
end

function M.probe(m)
  local items = vim.tbl_filter(function(item) return item.icon == "✗" and item.branch end, m.fallout or {})
  if #items == 0 then return end
  core.system({ "git", "fetch", "origin" }, m.dir, function(ok)
    if not ok then return end
    for _, item in ipairs(items) do probe_item(m, item) end
  end, NOPROMPT)
end

-- Fix runner: every git command runs async in the PR's worktree

local function exec(r, args, on_done, env)
  core.system(vim.list_extend({ "git" }, args), r.path or r.dir, guard(r, on_done), env)
end

local M_abort

local function git(r, args, on_done, env)
  r.busy = true
  exec(r, args, function(...)
    r.busy = false
    if r.abort_pending then return M_abort(r) end
    on_done(...)
  end, env)
end

local function state_file(r) return r.common .. "/pr-fix/" .. r.number .. ".json" end

-- Reads <wt>/.git without running git, so a planted config or fsmonitor hook never fires.
local function dotgit_target(path)
  local dotgit = path .. "/.git"
  local stat = vim.uv.fs_stat(dotgit)
  if not stat then return nil end
  if stat.type == "directory" then return vim.uv.fs_realpath(dotgit) end
  local target = (read(dotgit) or ""):match("^gitdir: ([^\n]+)")
  if not target then return nil end
  if not vim.startswith(target, "/") then target = path .. "/" .. target end
  return vim.uv.fs_realpath(target)
end

local function dotgit_ok(r)
  local known = r.gitdir and vim.uv.fs_realpath(r.gitdir)
  return known ~= nil and dotgit_target(r.path) == known
end

local function repair_dotgit(r)
  local linked = r.gitdir ~= r.path .. "/.git"
  local stat = vim.uv.fs_stat(r.path .. "/.git")
  if not linked or (stat and stat.type ~= "file") then return false end
  vim.fn.writefile({ "gitdir: " .. r.gitdir }, r.path .. "/.git")
  return dotgit_ok(r)
end

local function hijack_note(r)
  if repair_dotgit(r) then return "worktree .git was changed and has been restored" end
  return "worktree .git was changed · Neovim runs no git here until you restore it"
end

local function load_state(file)
  local decoded, state = pcall(vim.json.decode, read(file) or "")
  if decoded and type(state) == "table" and state.number and state.path then return state end
end

local function owns(r)
  if not exists(state_file(r)) then return true end
  local state = load_state(state_file(r))
  return not state or state.started == r.started
end

local function save_state(r)
  if not owns(r) then return end
  vim.fn.mkdir(r.common .. "/pr-fix", "p")
  local state = {
    number = r.number, title = r.title, branch = r.branch, base = r.base, from = r.from, path = r.path,
    orig = r.orig, stash = r.stash, stashed = r.stashed, stacked = r.stacked, started = r.started, lease = r.lease, diverged = r.diverged,
    marks = r.marks, adopted = r.adopted, gitdir = r.gitdir,
  }
  local ai = r.ai
  if ai then
    state.ai = {
      files = ai.files, all = ai.all, plan = ai.plan, note = ai.note, phase = ai.phase, why = ai.why, log = ai.log, unchecked = ai.unchecked,
      edits = ai.edits, snap = ai.snap, before = ai.before,
    }
  end
  vim.fn.writefile({ vim.json.encode(state) }, state_file(r))
end

local function drop_state(r)
  if r.common and owns(r) then os.remove(state_file(r)) end
end

local function in_progress(gitdir)
  return vim.iter({ "MERGE_HEAD", "rebase-merge", "rebase-apply" }):any(function(name) return exists(gitdir .. "/" .. name) end)
end

local function stash_args(r) return { "stash", "push", "--include-untracked", "-m", "fix #" .. r.number } end

local function marker_count(text)
  local count = 0
  for line in text:gmatch("[^\n]*") do
    if line:match("^<<<<<<<+ ") or line:match("^>>>>>>>+ ") then count = count + 1 end
  end
  return count
end

local function labels_of(r) return { ours = "#" .. r.number, theirs = r.base } end

local function back_to_orig(r, on_done)
  git(r, { "rev-parse", "HEAD" }, function(_, head)
    if vim.trim(head) == r.orig then return on_done(true) end
    git(r, { "reset", "--keep", r.orig }, function(ok, _, err) on_done(ok, err) end)
  end)
end

local function pop_stash(r, on_done)
  if not r.stash or r.popped then return on_done() end
  git(r, { "stash", "list", "--format=%gd%x09%H" }, function(_, out)
    local ref
    for line in out:gmatch("[^\n]+") do
      local name, sha = line:match("^(.-)\t(%x+)$")
      if sha == r.stash then ref = name end
    end
    if not ref then
      r.popped = true
      return on_done()
    end
    git(r, { "stash", "pop", ref }, function(ok)
      r.popped = true
      r.restored = ok
      if not ok then r.note = string.format('Stash "fix #%d" kept: putting it back conflicted.', r.number) end
      on_done()
    end)
  end)
end

local function fail(r, reason, note)
  local function end_fix(extra) finish(r, "failed", { reason = reason, note = extra or r.note }) end
  if not r.stash or r.popped then return end_fix(note) end
  local kept = string.format('Stash "fix #%d" kept: git stash pop puts it back', r.number)
  local function keep() end_fix(note and note .. " · " .. kept or kept) end
  if in_progress(r.gitdir) then return keep() end
  git(r, { "rev-parse", "HEAD" }, function(_, head)
    if vim.trim(head) ~= r.orig then return keep() end
    pop_stash(r, function() end_fix(note) end)
  end)
end

local function load_commits(r, tip, on_done)
  git(r, { "log", "--reverse", "--format=%h%x09%s", r.stacked .. ".." .. tip }, function(ok, out, err)
    if not ok then return on_done(false, err) end
    r.commits = {}
    for line in out:gmatch("[^\n]+") do
      local sha7, subject = line:match("^(%x+)\t(.*)$")
      r.commits[#r.commits + 1] = { sha7 = sha7, subject = subject, status = "pending" }
    end
    on_done(true)
  end)
end

local function mark_commits(r, on_done)
  if not r.stacked then return on_done() end
  git(r, { "log", "--format=%s", "origin/" .. r.base .. "..HEAD" }, function(_, out)
    local kept = {}
    for subject in out:gmatch("[^\n]+") do kept[subject] = true end
    for _, c in ipairs(r.commits) do
      if kept[c.subject] then
        c.status = "done"
      else
        c.status, c.note = "skipped", "skipped: already in " .. r.base
      end
    end
    on_done()
  end)
end

local function ready(r)
  git(r, { "rev-parse", "HEAD" }, function(_, head)
    r.merge_sha = vim.trim(head)
    pop_stash(r, function()
      mark_commits(r, function()
        git(r, { "log", "--format=%s", r.orig .. "..origin/" .. r.base }, function(_, out)
          r.contains = core.refs_of(vim.split(vim.trim(out), "\n"))
          set(r, { state = "ready", step = "push" })
          if r.push_after then
            r.push_after = nil
            M.push(r, false)
          end
        end)
      end)
    end)
  end)
end

local function stopped(r)
  local dir = r.gitdir .. "/rebase-merge/"
  local sha = vim.trim(read(dir .. "stopped-sha") or "")
  r.cur, r.total = tonumber(read(dir .. "msgnum")) or r.cur, tonumber(read(dir .. "end")) or r.total
  local found
  for i, c in ipairs(r.commits) do
    if sha:sub(1, #c.sha7) == c.sha7 then found = i end
  end
  for i, c in ipairs(r.commits) do
    if found and i < found and c.status == "pending" then c.status = "done" end
    if i == found then c.status = "current" end
  end
  r.files = {}
end

local scan

local function after_rebase_step(r, ok, err)
  if ok then return ready(r) end
  if not exists(r.gitdir .. "/rebase-merge") then return fail(r, "rebase failed: " .. git_error_line(err)) end
  git(r, { "ls-files", "-u", "-z" }, function(_, out)
    if out ~= "" then
      stopped(r)
      return scan(r)
    end
    git(r, { "diff", "--cached", "--quiet" }, function(nothing_staged)
      local empty = nothing_staged and exists(r.gitdir .. "/CHERRY_PICK_HEAD")
      if not empty or (r.skips or 0) >= 50 then
        local where = vim.fn.fnamemodify(r.path, ":~")
        return fail(r, "rebase failed: " .. git_error_line(err), "Rebase left in progress in " .. where .. " · git rebase --abort goes back")
      end
      r.skips = (r.skips or 0) + 1
      local current = vim.iter(r.commits):find(function(c) return c.status == "current" end)
      if current then current.status, current.note = "skipped", "skipped: already in " .. r.base end
      git(r, { "rebase", "--skip" }, function(skipped, _, skip_err) after_rebase_step(r, skipped, skip_err) end, EDITOR)
    end)
  end)
end

local function clean_index(r, on_done)
  git(r, { "grep", "--cached", "-l", "-z", "-E", "^(<{7,}|>{7,}) " }, function(_, out)
    local fixed, blocked = {}, {}
    for _, path in ipairs(vim.split(out, "\0", { plain = true })) do
      local text = path ~= "" and read(r.path .. "/" .. path)
      if text and marker_count(text) == 0 then
        fixed[#fixed + 1] = path
      elseif path ~= "" then
        blocked[#blocked + 1] = path
      end
    end
    if #fixed == 0 then return on_done(blocked) end
    git(r, vim.list_extend({ "add", "--" }, fixed), function() on_done(blocked) end, LITERAL)
  end)
end

local function block(r, paths)
  for _, path in ipairs(paths) do
    local f = vim.iter(r.files):find(function(file) return file.path == path end)
    if not f then
      f = { path = path, kind = "other", why = "conflict markers are staged" }
      r.files[#r.files + 1] = f
    end
    f.status, f.markers = "real", marker_count(read(r.path .. "/" .. path) or "")
  end
  set(r, { state = "resolving", step = r.ai and "review" or "resolve" })
end

local commit

local function finalize(r)
  if r.adopted == "rebase" then return set(r, { state = "resolving", step = "resolve" }) end
  if r.stacked then
    if not exists(r.gitdir .. "/rebase-merge") then return ready(r) end
    local current = vim.iter(r.commits):find(function(c) return c.status == "current" end)
    if current then
      local accepted = vim.iter(r.files):all(function(f) return f.status == "accepted" end)
      current.status = "done"
      current.note = plural(#r.files, "conflict") .. (accepted and ", fix accepted" or ", resolved")
    end
    return git(r, { "rebase", "--continue" }, function(ok, _, err) after_rebase_step(r, ok, err) end, EDITOR)
  end
  if not exists(r.gitdir .. "/MERGE_HEAD") then return ready(r) end
  if r.adopted == "merge" and not r.push_after then
    r.awaiting_p = true
    return set(r, { state = "resolving", step = "resolve", detail = "adopted · p commits and pushes after you review" })
  end
  clean_index(r, function(blocked)
    if #blocked > 0 then return block(r, blocked) end
    commit(r)
  end)
end

commit = function(r)
  git(r, { "commit", "--no-edit" }, function(ok, _, err)
    if ok then return ready(r) end
    local reason = "commit failed: " .. git_error_line(err)
    if r.adopted then
      r.push_after, r.awaiting_p = nil, true
      return set(r, { state = "resolving", step = "resolve", detail = reason .. " · x runs git merge --abort" })
    end
    git(r, { "merge", "--abort" }, function()
      back_to_orig(r, function(restored)
        if restored then return fail(r, reason, "nothing changed") end
        fail(r, reason, "Merge left in progress in " .. vim.fn.fnamemodify(r.path, ":~") .. " · git merge --abort goes back")
      end)
    end)
  end, EDITOR)
end

local function held(r)
  if r.ai and (r.ai.unchecked or r.ai.phase == "failed") then return true end
  return r.marks ~= nil and vim.iter(r.marks):any(function(_, mark) return mark.unsure ~= nil or mark.gave_up ~= nil end)
end

local function settle(r, unmerged, quiet)
  local clear, remaining = {}, 0
  for _, f in ipairs(r.files) do
    if unmerged[f.path] then
      if f.kind == "content" then
        f.markers = marker_count(read(r.path .. "/" .. f.path) or "")
        if f.markers == 0 then
          f.status = "resolved"
          if r.marks and r.marks[f.path] then r.marks[f.path].gave_up = nil end
          clear[#clear + 1] = f.path
        else
          f.status = f.easy and "ready" or "real"
          remaining = remaining + 1
        end
      else
        remaining = remaining + 1
      end
    elseif f.status == "real" then
      remaining = remaining + 1
    end
  end
  local function after()
    local again = r.scan_again
    r.scanning, r.scan_again, r.scanned = nil, nil, true
    if again then return scan(r, again == "quiet") end
    if quiet then return changed() end
    if remaining > 0 or held(r) then
      r.awaiting_p = nil
      local step = "resolve"
      if r.ai then
        step = "review"
      elseif r.stacked then
        step = "rebase"
      end
      return set(r, { state = "resolving", step = step })
    end
    finalize(r)
  end
  if #clear == 0 then return after() end
  git(r, vim.list_extend({ "add", "--" }, clear), after, LITERAL)
end

local function left_unmerged(r, f)
  f.markers = marker_count(read(r.path .. "/" .. f.path) or "")
  f.status = f.markers > 0 and "real" or "resolved"
  local mark = r.marks and r.marks[f.path]
  if f.markers == 0 and mark and mark.gave_up then mark.gave_up, mark.suggestion, mark.by = nil, nil, "you" end
end

scan = function(r, quiet)
  if r.scanning then
    if r.scan_again ~= "full" then r.scan_again = quiet and "quiet" or "full" end
    return
  end
  r.scanning = true
  git(r, { "ls-files", "-u", "-z" }, function(_, out)
    local records, unmerged, known = parse_stages(out), {}, {}
    for _, record in ipairs(records) do unmerged[record.path] = true end
    for _, f in ipairs(r.files) do
      known[f.path] = true
      if not unmerged[f.path] and f.status ~= "accepted" then left_unmerged(r, f) end
    end
    local fresh = vim.tbl_filter(function(record) return not known[record.path] end, records)
    classify(r.path, fresh, r.stacked and 3 or 2, labels_of(r), guard(r, function(files)
      vim.list_extend(r.files, files)
      settle(r, unmerged, quiet)
    end))
  end)
end

local function merge(r)
  set(r, { state = "merging", step = "merge" })
  git(r, { "merge", "--no-ff", "--no-edit", "origin/" .. r.base }, function(ok, _, err)
    if ok then return ready(r) end
    if exists(r.gitdir .. "/MERGE_HEAD") then return scan(r) end
    back_to_orig(r, function() fail(r, "merge failed: " .. git_error_line(err)) end)
  end)
end

local function rebase(r)
  set(r, { state = "rebasing", step = "rebase" })
  load_commits(r, "HEAD", function(ok, err)
    if not ok then return back_to_orig(r, function() fail(r, "rebase failed: " .. git_error_line(err)) end) end
    r.cur, r.total = 0, #r.commits
    git(r, { "rebase", "--onto", "origin/" .. r.base, r.stacked }, function(rebased, _, rebase_err)
      if rebased then return ready(r) end
      if not exists(r.gitdir .. "/rebase-merge") then
        return back_to_orig(r, function() fail(r, "rebase failed: " .. git_error_line(rebase_err)) end)
      end
      stopped(r)
      scan(r)
    end)
  end)
end

local function proceed(r)
  local function reset_then(on_done)
    if not (r.redo and r.orig == r.redo.merge_sha) then return on_done() end
    git(r, { "reset", "--keep", r.redo.orig }, function(ok, _, err)
      if not ok then return fail(r, "could not go back: " .. git_error_line(err)) end
      r.orig = r.redo.orig
      on_done()
    end)
  end
  reset_then(function()
    save_state(r)
    set(r, { state = "fetching", step = "fetch" })
    git(r, { "fetch", "origin" }, function(ok, _, err)
      if not ok then return fail(r, "fetch failed: " .. git_error_line(err)) end
      git(r, { "rev-parse", "origin/" .. r.branch }, function(found, out)
        if not found then return fail(r, "origin/" .. r.branch .. " not found") end
        r.lease = vim.trim(out)
        git(r, { "merge", "--ff-only", r.lease }, function()
          git(r, { "merge-base", "--is-ancestor", r.lease, "HEAD" }, function(contained)
            r.diverged = not contained
            save_state(r)
            if r.stacked then rebase(r) else merge(r) end
          end)
        end)
      end)
    end, NOPROMPT)
  end)
end

local function names_z(text) return vim.tbl_filter(function(name) return name ~= "" end, vim.split(text, "\0", { plain = true })) end

local function foreign_merge(r, on_done)
  local by_hand = " · finish it by hand or git merge --abort"
  git(r, { "merge-base", "--is-ancestor", "MERGE_HEAD", "origin/" .. r.base }, function(ours)
    if not ours then
      git(r, { "rev-parse", "--short", "MERGE_HEAD" }, function(_, sha)
        local ref = (read(r.gitdir .. "/MERGE_MSG") or ""):match("'([^']+)'") or vim.trim(sha)
        on_done(string.format("merge of %s in progress, not %s%s", ref, r.base, by_hand))
      end)
      return
    end
    git(r, { "diff", "--cached", "--name-only", "-z", "HEAD" }, function(_, staged)
      git(r, { "diff", "--name-only", "-z", "HEAD...MERGE_HEAD" }, function(_, incoming)
        local merged = {}
        for _, path in ipairs(names_z(incoming)) do merged[path] = true end
        local outside = vim.tbl_filter(function(path) return not merged[path] end, names_z(staged))
        if #outside > 0 then return on_done("staged changes outside the merge: " .. table.concat(outside, ", ") .. by_hand) end
        on_done()
      end)
    end)
  end)
end

local function adopt(r)
  local kind = exists(r.gitdir .. "/MERGE_HEAD") and "merge" or "rebase"
  git(r, { "rev-parse", "HEAD" }, function(_, head)
    local orig = vim.trim(head)
    if kind == "rebase" then
      orig = vim.trim(read(r.gitdir .. "/rebase-merge/orig-head") or read(r.gitdir .. "/rebase-apply/orig-head") or "")
    end
    if orig == "" then return fail(r, "a rebase is already in progress in " .. vim.fn.fnamemodify(r.path, ":~")) end
    local function take()
      r.orig, r.adopted = orig, kind
      r.note = "found a " .. kind .. " in progress (not started here)"
      save_state(r)
      set(r, { state = "resolving", step = "resolve" })
      if kind == "merge" then scan(r) end
    end
    if kind == "rebase" then return take() end
    foreign_merge(r, function(problem)
      if problem then return fail(r, problem) end
      take()
    end)
  end)
end

local function revive(r, state)
  for key, value in pairs(state) do r[key] = value end
  if state.ai then r.ai_wanted = nil end
  r.files, r.commits = {}, {}
  local intact = dotgit_ok(r)
  if not intact then r.detail = hijack_note(r) .. " · check it before going on" end
  set(r, { state = "paused", step = state.stacked and "rebase" or "resolve" })
  if intact then scan(r, true) end
end

local function rebasing_tree(out, branch)
  for path in out:gmatch("worktree ([^\n]+)") do
    local gitdir = path .. "/.git"
    if vim.fn.isdirectory(gitdir) == 0 then gitdir = (read(gitdir) or ""):match("^gitdir: ([^\n]+)") or gitdir end
    for _, dir in ipairs({ "rebase-merge", "rebase-apply" }) do
      if vim.trim(read(gitdir .. "/" .. dir .. "/head-name") or "") == "refs/heads/" .. branch then return path end
    end
  end
end

local function begin(r)
  git(r, { "worktree", "list", "--porcelain" }, function(_, out)
    local trees, main = core.parse_worktrees(out)
    r.path = trees[r.branch] or rebasing_tree(out, r.branch)
    if not r.path then return set(r, { state = "no_worktree", new_path = main .. "-wt/" .. r.branch:match("[^/]+$") }) end
    git(r, { "rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir" }, function(_, dirs)
      r.gitdir, r.common = unpack(vim.split(vim.trim(dirs), "\n"))
      local saved = load_state(state_file(r))
      git(r, { "rev-parse", "HEAD" }, function(_, head)
        if saved and (in_progress(r.gitdir) or vim.trim(head) ~= saved.orig) then return revive(r, saved) end
        if saved then os.remove(state_file(r)) end
        if in_progress(r.gitdir) then return adopt(r) end
        r.orig = vim.trim(head)
        git(r, { "status", "--porcelain" }, function(_, status)
          local dirty = vim.tbl_filter(function(line) return line ~= "" end, vim.split(status, "\n"))
          if #dirty > 0 then return set(r, { state = "dirty", dirty = dirty }) end
          proceed(r)
        end)
      end)
    end)
  end)
end

function M.start(m, item, redo)
  local live = find_fix(m.dir, item.number, unfinished)
  if live then return live end
  local function stale(old)
    local ended_badly = old.finished and (old.state == "failed" or old.state == "aborted")
    return old.kind == "fix" and old.number == item.number and ended_badly and repo_key(old.dir) == repo_key(m.dir)
  end
  for _, old in ipairs(vim.tbl_filter(stale, review.merges)) do core.untrack(old) end
  local r = {
    kind = "fix", dir = m.dir, number = item.number, title = item.title, branch = item.branch, base = item.base, from = m.number,
    stacked = item.onto, cmd = item.fix, redo = redo, started = os.time(), state = "fetching", step = "clean", files = {}, commits = {},
    cleanup = drop_state,
  }
  core.track(r)
  begin(r)
  return r
end

function M.redo(r)
  if r.state ~= "failed" then return end
  core.untrack(r)
  return M.start({ dir = r.dir, number = r.from }, {
    number = r.number, title = r.title, branch = r.branch, base = r.base, onto = r.stacked, fix = r.cmd,
  }, { orig = r.orig, merge_sha = r.merge_sha })
end

function M.stash(r)
  if r.state ~= "dirty" then return end
  set(r, { state = "fetching" })
  r.busy = true
  local function top(on_done)
    exec(r, { "rev-parse", "-q", "--verify", "refs/stash" }, function(_, out) on_done(vim.trim(out)) end)
  end
  top(function(before)
    exec(r, stash_args(r), function(ok, _, err)
      if not ok then
        r.busy = false
        return fail(r, "stash failed: " .. git_error_line(err))
      end
      top(function(after)
        r.busy = false
        if after ~= "" and after ~= before then r.stash, r.stashed = after, true end
        if r.abort_pending then return M_abort(r) end
        proceed(r)
      end)
    end)
  end)
end

function M.worktree(r)
  if r.state ~= "no_worktree" then return end
  git(r, { "worktree", "add", r.new_path, r.branch }, function(ok, _, err)
    if not ok then return fail(r, "worktree add failed: " .. git_error_line(err)) end
    begin(r)
  end)
end

local function reload(path)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then vim.cmd("checktime " .. buf) end
end

function M.accept(r, f)
  f = f or vim.iter(r.files):find(function(file) return file.status == "ready" end)
  if not f or f.status ~= "ready" or r.state ~= "resolving" or r.busy then return end
  local path = r.path .. "/" .. f.path
  if marker_count(read(path) or "") == 0 then return scan(r) end
  local file = io.open(path, "wb")
  file:write(f.res.result)
  file:close()
  git(r, { "add", "--", f.path }, function()
    f.status = "accepted"
    reload(path)
    scan(r)
  end, LITERAL)
end

function M.accept_all(r, on_done)
  local paths = {}
  r.marks = r.marks or {}
  for _, f in ipairs(r.files) do
    if f.status == "ready" then
      local path = r.path .. "/" .. f.path
      if marker_count(read(path) or "") > 0 then
        local file = io.open(path, "wb")
        file:write(f.res.result)
        file:close()
      end
      paths[#paths + 1] = f.path
    end
  end
  if #paths == 0 then return on_done() end
  git(r, vim.list_extend({ "add", "--" }, paths), function()
    for _, f in ipairs(r.files) do
      if vim.tbl_contains(paths, f.path) then
        f.status = "accepted"
        r.marks[f.path] = { by = "easy" }
      end
    end
    for _, path in ipairs(paths) do reload(r.path .. "/" .. path) end
    on_done()
  end, LITERAL)
end

function M.rescan(r)
  if r.state == "resolving" and not r.busy then scan(r) end
end

function M.resume(r)
  if r.state ~= "paused" then return end
  if not dotgit_ok(r) then return set(r, { detail = hijack_note(r) }) end
  r.detail = nil
  set(r, { state = "resolving", step = r.stacked and "rebase" or "resolve" })
  if not (r.stacked and exists(r.gitdir .. "/rebase-merge")) then return scan(r) end
  local tip = vim.trim(read(r.gitdir .. "/rebase-merge/orig-head") or "")
  load_commits(r, tip ~= "" and tip or r.orig, function()
    stopped(r)
    scan(r)
  end)
end

local function follow_ci(r, polls)
  local function again()
    vim.defer_fn(guard(r, function() follow_ci(r, polls + 1) end), review.settle_ms)
  end
  core.view_pr(r.number, r.dir, guard(r, function(pr)
    if not pr then
      if polls >= core.SETTLE_POLLS then return fail(r, "could not read PR #" .. r.number) end
      return again()
    end
    r.draft = pr.isDraft
    if pr.headRefOid ~= r.pushed and polls < core.SETTLE_POLLS then return again() end
    local checks = core.checks_of(pr)
    local counts = core.tally(checks)
    r.ci = counts
    if counts.fail > 0 then
      local failing = vim.iter(checks):find(function(c) return c.state == "fail" and c.url end)
      return finish(r, "failed", {
        reason = "CI failed after the fix: " .. table.concat(core.names_of(checks, "fail"), ", "),
        log_url = failing and failing.url,
      })
    end
    if counts.pending > 0 then
      r.ci_since = r.ci_since or os.time()
      local elapsed = os.time() - r.ci_since
      if elapsed > review.ci_timeout then return fail(r, "CI still running after " .. core.clock(elapsed)) end
      return again()
    end
    if counts.total == 0 and polls < core.SETTLE_POLLS then return again() end
    local ci = counts.total > 0 and string.format(" · CI %d/%d", counts.pass, counts.total) or " · no CI checks"
    finish(r, "fixed", { reason = "pushed " .. r.pushed:sub(1, 7) .. ci })
  end))
end

function M.push(r, force)
  if r.awaiting_p and r.state == "resolving" and not r.busy and not force then
    r.awaiting_p, r.push_after, r.detail = nil, true, nil
    return finalize(r)
  end
  if r.state ~= "ready" or r.busy or force ~= (r.stacked ~= nil) then return end
  if r.diverged then
    return fail(r, "branch diverged: origin/" .. r.branch .. " has commits not in this branch", "Nothing was pushed · reconcile " .. r.branch .. " by hand")
  end
  if force and not r.lease then return fail(r, "lease unknown, f to redo") end
  local args = { "push", "origin", r.branch }
  if force then args = { "push", string.format("--force-with-lease=refs/heads/%s:%s", r.branch, r.lease), "origin", r.branch } end
  set(r, { state = "pushing", step = "push" })
  git(r, args, function(ok, _, err)
    if ok then
      r.pushed = r.merge_sha
      drop_state(r)
      set(r, { state = "ci", step = "ci" })
      return follow_ci(r, 0)
    end
    local moved = vim.iter({ "rejected", "stale info", "fetch first", "non-fast-forward" }):any(function(text) return err:find(text, 1, true) end)
    if not moved then return fail(r, "push failed: " .. git_error_line(err)) end
    fail(r, "push rejected: the branch moved on GitHub", (r.stacked and "Rebased commits" or "Merge commit") .. " kept locally · f fetch and redo")
  end, NOPROMPT)
end

local M_abort_retry

local function stash_tail(r)
  if not r.stashed then return "" end
  if r.restored then return ", stash restored" end
  return string.format(', stash kept as "fix #%d"', r.number)
end

local function restash(r, on_done)
  if not (r.stash and r.popped) then return on_done() end
  git(r, stash_args(r), function(ok, out)
    if not ok or out:find("No local changes", 1, true) then return on_done() end
    git(r, { "rev-parse", "stash@{0}" }, function(_, sha)
      r.stash, r.popped, r.restored = vim.trim(sha), false, false
      on_done()
    end)
  end)
end

local function before_of(r) return r.ai and r.ai.before end

local function changed_in_run(r, path)
  local before = before_of(r)
  return not (before.dirty[path] or before.untracked[path])
end

-- Unstaged edits Claude left on merged files make `merge --abort` refuse ("not uptodate").
local function unedit(r, on_done)
  if not before_of(r) then return on_done() end
  git(r, { "ls-files", "-u", "-z" }, function(_, stages)
    local open = {}
    for _, f in ipairs(parse_stages(stages)) do open[f.path] = true end
    git(r, { "diff", "--name-only", "-z" }, function(_, out)
      local edited = vim.tbl_filter(function(path) return not open[path] and changed_in_run(r, path) end, names_z(out))
      if #edited == 0 then return on_done() end
      git(r, vim.list_extend({ "checkout", "--" }, edited), function() on_done() end, LITERAL)
    end)
  end)
end

local function discard(r, on_done)
  if not before_of(r) then return on_done({}) end
  git(r, { "ls-files", "-o", "--exclude-standard", "-z" }, function(_, untracked)
    local removed = vim.tbl_filter(function(path) return changed_in_run(r, path) end, names_z(untracked))
    for _, path in ipairs(removed) do os.remove(r.path .. "/" .. path) end
    git(r, { "diff", "--name-only", "-z", "HEAD" }, function(_, dirty)
      local touched = vim.tbl_filter(function(path) return changed_in_run(r, path) end, names_z(dirty))
      if #touched == 0 then return on_done(removed) end
      git(r, vim.list_extend({ "checkout", "HEAD", "--" }, touched), function() on_done(removed) end, LITERAL)
    end)
  end)
end

local function leftover(r, status)
  local paths = vim.tbl_map(function(entry) return entry:sub(4) end, names_z(status))
  if before_of(r) then paths = vim.tbl_filter(function(path) return changed_in_run(r, path) end, paths) end
  return paths[1]
end

local function verify(r, on_done)
  local args = { "diff", "--cached", "--name-only", "-z" }
  if before_of(r) then args = { "status", "--porcelain", "-z", "--no-renames", "--untracked-files=all" } end
  git(r, { "rev-parse", "HEAD" }, function(_, head)
    git(r, args, function(_, status)
      if vim.trim(head) ~= r.orig then return on_done("HEAD is not " .. r.orig:sub(1, 7)) end
      if exists(r.gitdir .. "/MERGE_HEAD") then return on_done("the merge is still in progress") end
      local path = before_of(r) and leftover(r, status) or names_z(status)[1]
      if path then return on_done("changes are left over in " .. path) end
      on_done()
    end)
  end)
end

local function unlock(r, on_done)
  local lock = r.gitdir .. "/index.lock"
  if not exists(lock) or (r.ai and r.ai.proc) then return on_done(false) end
  local started = pcall(vim.system, { "lsof", "-t", lock }, { text = true }, function(out)
    vim.schedule(function()
      local free = out.code ~= 0 and vim.trim(out.stdout or "") == ""
      if free then os.remove(lock) end
      on_done(free)
    end)
  end)
  if not started then on_done(false) end
end

local function aborted_headline(r, removed)
  local headline = "back at " .. r.orig:sub(1, 7) .. " exactly" .. stash_tail(r)
  if not r.ai then return headline end
  local edits = r.ai.edits or 0
  headline = "cancelled with x · " .. headline
  if edits > 0 then headline = headline .. ", Claude's " .. edits .. " edits discarded" end
  if #removed > 0 then headline = headline .. ", removed new files: " .. table.concat(removed, ", ") end
  return headline
end

local function undo(r, why)
  restash(r, function()
    back_to_orig(r, function(ok, err)
      discard(r, function(removed)
        verify(r, function(problem)
          if ok and not problem then
            return pop_stash(r, function()
              r.aborting = false
              finish(r, "aborted", { headline = aborted_headline(r, removed) })
            end)
          end
          local function give_up()
            r.aborting, r.abort_retried = false, nil
            set(r, { detail = "could not go back: " .. git_error_line(err or why or problem or "") })
          end
          if r.abort_retried then return give_up() end
          unlock(r, function(removed_lock)
            if removed_lock then return M_abort_retry(r) end
            give_up()
          end)
        end)
      end)
    end)
  end)
end

M_abort = function(r)
  local untouchable = r.finished or r.pushed or r.aborting or r.state == "pushing"
  if untouchable then return end
  if r.busy then return set(r, { abort_pending = true }) end
  r.abort_pending, r.scanning, r.scan_again = nil, nil, nil
  local nothing_started = r.state == "dirty" or r.state == "no_worktree" or not (r.gitdir and r.orig)
  if nothing_started then
    local made = r.new_path and exists(r.new_path .. "/.git")
    return finish(r, "aborted", { headline = made and "worktree created, nothing else changed" or "nothing changed" })
  end
  if not dotgit_ok(r) and not repair_dotgit(r) then return set(r, { detail = "could not go back: worktree .git was changed" }) end
  r.aborting = true
  local function then_undo(_, _, err) undo(r, err) end
  if exists(r.gitdir .. "/MERGE_HEAD") then
    return unedit(r, function() git(r, { "merge", "--abort" }, then_undo) end)
  end
  if exists(r.gitdir .. "/rebase-merge") or exists(r.gitdir .. "/rebase-apply") then
    return git(r, { "rebase", "--abort" }, then_undo)
  end
  undo(r)
end
M_abort_retry = function(r)
  r.aborting, r.abort_retried = false, true
  M_abort(r)
end
M.abort = M_abort
M.dotgit_ok = dotgit_ok
M.hijack_note = hijack_note
M.git_error_line = git_error_line
M.save_state = save_state
M.marker_count = marker_count
M.parse_stages = parse_stages
M.read = read

function M.commands(t) review.ui.copy_fix(t.item and t.item.fix or t.merge.cmd) end

function M.latest(dir, number, since)
  return find_fix(dir, number, function(r) return r.started >= (since or 0) end)
end

-- Recovery: rebuild paused records from <git-common-dir>/pr-fix after a restart

local restoring = {}

local function restore(dir, common, file)
  local state = load_state(file)
  if not state then return os.remove(file) end
  local id = repo_key(dir) .. "#" .. state.number
  if restoring[id] or find_fix(dir, state.number, unfinished) then return end
  local function track_revived(gitdir)
    if find_fix(dir, state.number, unfinished) then return end
    local r = { kind = "fix", dir = dir, gitdir = gitdir, common = common, cleanup = drop_state }
    revive(r, state)
    core.track(r)
  end
  local function check(gitdir)
    if not dotgit_ok({ path = state.path, gitdir = gitdir }) then return track_revived(gitdir) end
    restoring[id] = true
    core.system({ "git", "rev-parse", "HEAD" }, state.path, function(_, head)
      restoring[id] = nil
      if not in_progress(gitdir) and vim.trim(head) == state.orig then return os.remove(file) end
      track_revived(gitdir)
    end)
  end
  if state.gitdir then return check(state.gitdir) end
  restoring[id] = true
  core.system({ "git", "rev-parse", "--path-format=absolute", "--absolute-git-dir" }, state.path, function(ok, gitdir)
    restoring[id] = nil
    if ok then check(vim.trim(gitdir)) end
  end)
end

function M.refresh(dir)
  for _, r in ipairs(review.merges) do
    if r.kind == "fix" and r.state == "resolving" and not r.finished then M.rescan(r) end
  end
  core.system({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, dir, function(ok, out)
    if not ok then return end
    local common = vim.trim(out)
    for _, file in ipairs(vim.fn.glob(common .. "/pr-fix/*.json", false, true)) do restore(dir, common, file) end
  end)
end

vim.api.nvim_create_autocmd("BufWritePost", {
  group = vim.api.nvim_create_augroup("PrFix", { clear = true }),
  callback = function(args)
    local file = vim.fs.normalize(vim.api.nvim_buf_get_name(args.buf))
    for _, r in ipairs(review.merges) do
      if r.kind == "fix" and r.state == "resolving" and vim.startswith(file, r.path .. "/") then M.rescan(r) end
    end
  end,
})

return M
