local M = {}

local review = require("config.review_pr")
local fix = require("config.pr_fix")
local core = review.core
local set, guard, changed = core.set, core.guard, core.changed

M.cmd = "claude"
M.limit = 1200
M.max_agents = 2
M.plan_at = 50
M.model = nil
M.budget = nil
M.dir = vim.fn.stdpath("state") .. "/pr-ai"
M.keep = 86400

local ACTIVE = { planning = true, running = true, checking = true }
local EDITS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }
local KINDS = { format = true, reapply = true, merge = true }
local LANE = { gave_up = true, paused = true, stopped = true }

local function exists(path) return vim.uv.fs_stat(path) ~= nil end

local function now()
  local sec, usec = vim.uv.gettimeofday()
  return sec + usec / 1e6
end

local function decode(text)
  local ok, value = pcall(vim.json.decode, text)
  return ok and type(value) == "table" and value or nil
end

local function str(value, default) return type(value) == "string" and value or default end

local function list(value) return type(value) == "table" and value or {} end

local function first_line(text) return vim.trim(vim.split(str(text, ""), "\n", { plain = true })[1]) end

local function squash(text) return (text:gsub("%s+", "")) end

local function relative(r, path) return vim.startswith(path, r.path .. "/") and path:sub(#r.path + 2) or path end

local function set_of(items)
  local out = {}
  for _, item in ipairs(items) do out[item] = true end
  return out
end

-- Pure helpers

function M.parse_event(line)
  local event = decode(line)
  if not event or type(event.type) ~= "string" then return nil end
  if event.type == "result" then
    return {
      type = "result", is_error = event.is_error == true, text = str(event.result), structured = event.structured_output,
      cost = tonumber(event.total_cost_usd), denials = list(event.permission_denials),
    }
  end
  for _, block in ipairs(type(event.message) == "table" and list(event.message.content) or {}) do
    if block.type == "text" then return { type = "text", text = str(block.text, "") } end
    if block.type == "tool_use" then
      local input = list(block.input)
      return { type = "tool", name = str(block.name, ""), path = str(input.file_path), command = str(input.command) }
    end
    if block.type == "tool_result" then
      local content = block.content
      if type(content) == "table" then
        content = table.concat(vim.tbl_map(function(part) return str(type(part) == "table" and part.text, "") end, content), "\n")
      end
      return { type = block.is_error and "tool_error" or "tool_result", text = str(content, "") }
    end
  end
  return { type = event.type }
end

function M.report_of(event)
  if type(event.structured) == "table" then return event.structured end
  local text = event.text
  if not text then return nil end
  local last
  for block in text:gmatch("```json%s*(.-)```") do last = block end
  return (last and decode(last)) or decode(text)
end

function M.plan_of(raw, files)
  if type(raw) ~= "table" then return nil, "no plan" end
  local wanted, taken, groups = set_of(files), {}, {}
  for _, entry in ipairs(list(raw.groups)) do
    if type(entry) == "table" and KINDS[entry.kind] then
      local group = { title = str(entry.title, entry.kind), strategy = str(entry.strategy, ""), kind = entry.kind, files = {}, keep = {} }
      for _, path in ipairs(list(entry.files)) do
        if wanted[path] and not taken[path] then
          taken[path] = true
          group.files[#group.files + 1] = path
        end
      end
      local mine = set_of(group.files)
      for _, keep in ipairs(list(entry.keep)) do
        if type(keep) == "table" and mine[keep.path] and type(keep.lines) == "table" then group.keep[keep.path] = keep.lines end
      end
      if #group.files > 0 then groups[#groups + 1] = group end
    end
  end
  if #groups == 0 then return nil, "empty plan" end
  local missing = vim.tbl_filter(function(path) return not taken[path] end, files)
  if #missing > 0 then
    groups[#groups + 1] = { title = "not in the plan", strategy = "Claude merges each one", kind = "merge", files = missing, keep = {} }
  end
  return { summary = str(raw.summary, ""), minutes = tonumber(raw.minutes), groups = groups }
end

function M.present(content, line) return squash(content):find(squash(line), 1, true) ~= nil end

local function unsure_paths(r)
  local paths = {}
  for _, f in ipairs(r.files) do
    if r.marks and r.marks[f.path] and r.marks[f.path].unsure then paths[#paths + 1] = f.path end
  end
  local outside = {}
  for path, mark in pairs(r.marks or {}) do
    if mark.unsure and not vim.tbl_contains(paths, path) then outside[#outside + 1] = path end
  end
  table.sort(outside)
  return vim.list_extend(paths, outside)
end

M.unsure_paths = unsure_paths

function M.unresolved(r)
  return vim.tbl_filter(function(f) return f.status == "real" or f.status == "ready" end, r.files)
end

local function gave_up_paths(r)
  return vim.tbl_filter(function(path) return r.marks[path].gave_up ~= nil end, vim.tbl_keys(r.marks or {}))
end

local function attention(r)
  local ai = r.ai
  if r.state == "plan" or ai.phase == "plan" then return "plan ready" end
  if r.state == "claude" then return ai.phase == "failed" and "failed" or nil end
  if r.state == "ready" then return "ready to push" end
  if ai.phase == "paused" or ai.phase == "error" then return "paused" end
  if ai.phase == "stopped" then return "step " .. ((ai.stopped or {}).group or "?") .. " stopped" end
  if ai.phase == "gave_up" or #gave_up_paths(r) > 0 then return "gave up" end
  local unsure = #unsure_paths(r)
  if unsure > 0 then return unsure .. " unsure" end
  if ai.phase == "done" or ai.phase == "review" then return "ready to push" end
end

local function progress_text(r)
  local ai = r.ai
  if ai.phase == "planning" or ai.phase == "checking" then return ai.phase end
  if ai.plan then return string.format("plan %d/%d", ai.group or 1, #ai.plan.groups) end
  return string.format("%d/%d", ai.resolved or 0, ai.total or 0)
end

-- Short state for a PR row elsewhere (the picker): what needs you, else progress.
function M.label(r)
  if not r.ai then return nil end
  local text = attention(r)
  if text then return text end
  if r.state == "claude" and r.ai.phase == "queued" then return "queued" end
  return progress_text(r)
end

local function live(r)
  return r.kind == "fix" and not r.finished and r.ai ~= nil and vim.tbl_contains({ "claude", "plan", "resolving", "ready" }, r.state)
end

function M.status_text(records)
  local active, queued, parts, newest = 0, 0, {}, nil
  for _, r in ipairs(vim.tbl_filter(live, records)) do
    local phase = r.state == "claude" and r.ai.phase
    if ACTIVE[phase] then
      active = active + 1
      newest = newest or r
    elseif phase == "queued" then
      queued = queued + 1
    end
    local text = attention(r)
    if text and #parts < 2 then parts[#parts + 1] = "#" .. r.number .. " " .. text end
  end
  if active + queued + #parts == 0 and not newest then return nil end
  local head = active > 0 and "◆" .. active or "◆"
  if queued > 0 then head = head .. " +" .. queued .. " queued" end
  local tail
  if #parts > 0 then
    tail = table.concat(parts, " · ")
  elseif newest then
    tail = "#" .. newest.number .. " " .. progress_text(newest)
  else
    return head, false
  end
  return head .. (active > 0 and " · " or " ") .. tail, #parts > 0
end

function M.lane(r)
  return r.kind == "fix" and not r.finished and r.ai ~= nil and (r.state == "claude" or (r.state == "resolving" and LANE[r.ai.phase] == true))
end

function M.mark_of(r, path)
  local mark = (r.marks or {})[path] or {}
  local f = vim.iter(r.files):find(function(file) return file.path == path end)
  if mark.unsure then return "?", "PrOrange" end
  if f and (f.status == "real" or f.status == "ready") then return "✗", "PrRed" end
  if mark.by == "claude" then return "◆", "PrYellow" end
  if mark.by == "you" then return "✎", "PrGreen" end
  if f and f.status == "accepted" then return "=", "PrDim" end
  return "✎", "PrGreen"
end

function M.counts(r)
  local counts = { ["="] = 0, ["◆"] = 0, ["✎"] = 0, ["?"] = 0 }
  local seen = {}
  local function count(path)
    seen[path] = true
    local icon = M.mark_of(r, path)
    if counts[icon] then counts[icon] = counts[icon] + 1 end
  end
  for _, f in ipairs(r.files) do count(f.path) end
  for path in pairs(r.marks or {}) do
    if not seen[path] then count(path) end
  end
  return counts
end

function M.merge_paths(r)
  local plan = r.ai.plan
  local paths = {}
  if not plan then
    for _, f in ipairs(r.files) do
      if (r.marks[f.path] or {}).by == "claude" then paths[#paths + 1] = f.path end
    end
    return paths
  end
  for _, group in ipairs(plan.groups) do
    if group.kind == "merge" then vim.list_extend(paths, group.files) end
  end
  return paths
end

function M.wants_strategy(r)
  local ai = r.ai
  return ai ~= nil and (r.state == "plan" or (r.state == "resolving" and (ai.phase == "stopped" or ai.phase == "gave_up")))
end

function M.group_of(plan, path)
  for i, group in ipairs(plan and plan.groups or {}) do
    if vim.tbl_contains(group.files, path) then return i end
  end
end

function M.group_progress(r, i)
  local group = r.ai.plan.groups[i]
  local handed = set_of(r.ai.files or {})
  local open = set_of(vim.tbl_map(function(f) return f.path end, M.unresolved(r)))
  if r.state == "claude" and r.ai.unmerged then open = r.ai.unmerged end
  local total, left = 0, 0
  for _, path in ipairs(group.files) do
    if handed[path] then
      total = total + 1
      if open[path] then left = left + 1 end
    end
  end
  return total - left, total
end

-- Claude command line and prompts

local PLAN_SCHEMA = [[{"type":"object","required":["summary","groups"],"properties":{"summary":{"type":"string"},"minutes":{"type":"integer"},]]
  .. [["groups":{"type":"array","items":{"type":"object","required":["title","strategy","kind","files"],"properties":{]]
  .. [["title":{"type":"string"},"strategy":{"type":"string"},"kind":{"enum":["format","reapply","merge"]},]]
  .. [["files":{"type":"array","items":{"type":"string"}},"keep":{"type":"array","items":{"type":"object","required":["path","lines"],]]
  .. [["properties":{"path":{"type":"string"},"lines":{"type":"array","items":{"type":"string"}}}}}}}}}}]]

local RUN_SCHEMA = [[{"type":"object","required":["status","files"],"properties":{"status":{"enum":["done","stopped"]},]]
  .. [["stopped":{"type":"object","properties":{"group":{"type":"integer"},"reason":{"type":"string"},"suggestion":{"type":"string"}}},]]
  .. [["files":{"type":"array","items":{"type":"object","required":["path","result"],"properties":{"path":{"type":"string"},]]
  .. [["result":{"enum":["resolved","unsure","gave_up"]},"note":{"type":"string"},"line":{"type":"integer"},"guess":{"type":"string"},]]
  .. [["suggestion":{"type":"string"}}}}}}]]

local DENIED = {
  "Bash(git push:*)", "Bash(git commit:*)", "Bash(git merge:*)", "Bash(git reset:*)", "Bash(git rebase:*)", "Bash(git stash:*)",
  "Bash(git switch:*)", "Bash(git restore:*)", "Bash(git worktree:*)", "Bash(git clean:*)", "Bash(git config:*)", "Bash(gh:*)",
  "Bash(git diff --output:*)", "Bash(git log --output:*)", "Bash(git * --output*)", "Bash(git diff --no-index:*)", "Bash(git * --no-index*)",
  "Bash(* --plugin*)", "Bash(* --config-precedence*)",
}

local READ_GIT = {
  "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git ls-files:*)", "Bash(git cat-file:*)",
  "Bash(git merge-base:*)", "Bash(git rev-parse:*)", "Bash(git blame:*)",
}

local WRITE_GIT = {
  "Bash(git add:*)", "Bash(git rm:*)", "Bash(git checkout --theirs:*)", "Bash(git checkout --ours:*)",
}

local function formatter(r)
  if not (r.common and vim.fs.basename(r.common) == ".git") then return nil end
  local bin = vim.fs.dirname(r.common) .. "/node_modules/.bin/prettier"
  return vim.fn.executable(bin) == 1 and { name = "prettier", bin = bin } or nil
end

local PROTECTED = { "node_modules/**", "**/.prettierrc*", "**/prettier.config.*", "**/.prettierignore" }

local function dotgit_spellings()
  local out = {}
  for i = 0, 7 do
    out[#out + 1] = "." .. (i % 2 == 1 and "G" or "g") .. (math.floor(i / 2) % 2 == 1 and "I" or "i") .. (math.floor(i / 4) == 1 and "T" or "t")
  end
  return out
end

local function argv_of(r, planning)
  local scope = "//" .. r.path:sub(2) .. "/**"
  local args = {
    M.cmd, "-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--strict-mcp-config",
    "--settings", '{"disableAllHooks":true}', "--permission-mode", "dontAsk", "--json-schema", planning and PLAN_SCHEMA or RUN_SCHEMA,
  }
  if M.model then vim.list_extend(args, { "--model", M.model }) end
  if M.budget then vim.list_extend(args, { "--max-budget-usd", tostring(M.budget) }) end
  vim.list_extend(args, { "--disallowedTools" })
  vim.list_extend(args, DENIED)
  local protected = vim.tbl_map(function(dir) return "//" .. dir:sub(2) .. "/**" end, vim.fn.uniq(vim.fn.sort({ r.path .. "/.git", r.gitdir, r.common })))
  for _, name in ipairs(dotgit_spellings()) do
    vim.list_extend(protected, { "//" .. r.path:sub(2) .. "/" .. name, "//" .. r.path:sub(2) .. "/" .. name .. "/**" })
  end
  for _, pattern in ipairs(PROTECTED) do protected[#protected + 1] = "//" .. r.path:sub(2) .. "/" .. pattern end
  for _, pattern in ipairs(protected) do vim.list_extend(args, { "Edit(" .. pattern .. ")", "Write(" .. pattern .. ")" }) end
  local allowed = { "Read(" .. scope .. ")" }
  if planning then
    vim.list_extend(args, { "--tools", "Read,Glob,Grep,Bash,Skill", "--allowedTools" })
  else
    vim.list_extend(args, { "--tools", "Read,Edit,Write,Glob,Grep,Bash,Skill", "--allowedTools" })
    vim.list_extend(allowed, { "Edit(" .. scope .. ")", "Write(" .. scope .. ")" })
  end
  vim.list_extend(allowed, { "Glob", "Grep", "Skill" })
  vim.list_extend(allowed, READ_GIT)
  if not planning then
    vim.list_extend(allowed, WRITE_GIT)
  end
  return vim.list_extend(args, allowed)
end

local function context_of(r, files)
  return string.format(
    'PR #%d "%s" on branch %s. `git merge origin/%s` is in progress (MERGE_HEAD is set). In conflict markers "ours"/HEAD is #%d, "theirs" is %s.\n'
      .. "Conflicted files (%d):\n%s",
    r.number, r.title, r.branch, r.base, r.number, r.base, #files, table.concat(files, "\n")
  )
end

local function plan_prompt(r, fmt)
  local ai = r.ai
  local lines = {
    "Plan how to resolve the merge conflicts in this git worktree. This step is read-only: don't edit, stage or format anything. "
      .. "You run unattended; nobody can answer questions.",
    "Use the mattpocock-skills:resolving-merge-conflicts skill for its steps 1 and 2 only (see the state, find why each side changed).",
    "",
    context_of(r, ai.files),
    "",
    "Put every file in exactly one group, by how it should be resolved:",
    string.format(
      '- "reapply": #%d also changed code. Resolution: take %s\'s file, re-apply #%d\'s code changes; Neovim formats afterwards. '
        .. 'In "keep" list every line of #%d\'s code that must be in the result, exactly as #%d wrote it.',
      r.number, r.base, r.number, r.number, r.number
    ),
    '- "merge": both sides changed logic; each file is merged by judgement.',
    "Don't run any formatter yourself.",
    "Prefer few groups. title at most 30 characters, strategy at most 40. summary: one sentence on why this plan is safe. "
      .. "minutes: your estimate to run it.",
  }
  if fmt then
    table.insert(lines, 7, string.format(
      '- "format": the sides differ only in formatting. Resolution: take %s\'s file; Neovim re-runs prettier with #%d\'s config.', r.base, r.number
    ))
  else
    lines[#lines + 1] = 'There is no usable prettier config on ' .. r.base .. ': don\'t use the "format" kind; put those files in "reapply" or "merge".'
  end
  if ai.plan and ai.note then
    lines[#lines + 1] = "Previous plan: " .. vim.json.encode({ summary = ai.plan.summary, groups = ai.plan.groups })
      .. ". The user wants it changed: " .. ai.note
  end
  return table.concat(lines, "\n")
end

local function run_prompt(r)
  local ai = r.ai
  local lines = {
    "Resolve the merge conflicts in this git worktree. You run unattended; nobody can answer questions.",
    "Use the mattpocock-skills:resolving-merge-conflicts skill. The rules below override it where they differ.",
    "",
    context_of(r, ai.files):gsub("Conflicted files", "Files to resolve"),
    "",
  }
  if ai.plan then
    local handed = set_of(ai.files)
    lines[#lines + 1] = "Plan approved by the user. Do the groups in order:"
    for i, group in ipairs(ai.plan.groups) do
      local mine = vim.tbl_filter(function(path) return handed[path] end, group.files)
      if #mine > 0 then
        lines[#lines + 1] = string.format("Group %d · %s · %s: %s", i, group.kind, group.title, group.strategy)
        lines[#lines + 1] = "  files: " .. table.concat(mine, ", ")
        for _, path in ipairs(mine) do
          if group.kind == "reapply" and group.keep[path] then
            lines[#lines + 1] = "  keep in " .. path .. ": " .. table.concat(group.keep[path], " | ")
          end
        end
      end
    end
    lines[#lines + 1] = "If a group can't be done as planned (for example the formatter would change files that aren't listed, or a file needs more "
      .. "than the group's strategy), stop before doing it: don't start later groups, and report status \"stopped\" with the group number, "
      .. "the reason and a one-line suggestion for changing the plan."
  end
  if ai.note then lines[#lines + 1] = "Instructions from the user: " .. ai.note end
  vim.list_extend(lines, {
    "",
    "Rules:",
    "- Change only the files listed above, and only inside this directory.",
    "- After resolving a file, stage it: git add -- <file>.",
    "- Never commit, push, reset, stash, rebase, switch branches, or run git merge (including --continue and --abort). "
      .. "Leave the merge in progress; the user reviews and commits.",
    "- Don't install anything and don't run tests, builds, typechecks or any formatter (prettier or others). "
      .. "Neovim formats the files you resolved after you finish.",
    "- Don't invent behaviour; keep both sides' intent.",
    '- Not sure about a file? Still write your best guess without markers, stage it, and report it "unsure" with the reason, '
      .. "the line of the guess and a one-line guess.",
    "- A file that can't be merged sensibly (for example a lockfile that must be regenerated): leave its markers, don't stage it, "
      .. 'and report it "gave_up" with the reason and what would fix it.',
    '- Before each file print one line: "<file>: <what you are doing>".',
    "",
    'Report: status "done" or "stopped" (with stopped.group/reason/suggestion). In files, list every file you merged by judgement and every '
      .. "unsure or gave_up file: path, result, note (one line: what you kept from each side), plus line/guess for unsure and suggestion "
      .. "for gave_up. Files resolved mechanically by a plan group may be left out.",
  })
  return table.concat(lines, "\n")
end

-- Runner

local queue, procs = {}, {}
local logs = 0
local pump
local check
local kill

local function clock_text(secs)
  if secs < 60 then return secs .. "s" end
  return math.floor(secs / 60) .. "m"
end

local LITERAL = { GIT_LITERAL_PATHSPECS = "1" }

local function sync_git(r, args)
  local out = vim.system(vim.list_extend({ "git", "--no-optional-locks" }, args), { cwd = r.path, text = true, env = LITERAL }):wait()
  return out.stdout or ""
end

local function names_z(text) return vim.tbl_filter(function(name) return name ~= "" end, vim.split(text, "\0", { plain = true })) end

local function index_of(text)
  local entries = {}
  for _, record in ipairs(names_z(text)) do
    local meta, path = record:match("^(%d+ %x+ %d)\t(.+)$")
    if path then entries[path] = (entries[path] and entries[path] .. "," or "") .. meta end
  end
  return entries
end

local function unmerged_set(r)
  local out = {}
  for _, f in ipairs(fix.parse_stages(sync_git(r, { "ls-files", "-u", "-z" }))) do out[f.path] = true end
  return out
end

local function digest(r, path) return vim.fn.sha256(fix.read(r.path .. "/" .. path) or "") end

local function snapshot(r, handed)
  local work = {}
  for path in pairs(unmerged_set(r)) do
    if not handed[path] then work[path] = digest(r, path) end
  end
  return {
    index = index_of(sync_git(r, { "ls-files", "-s", "-z" })), work = work,
    untracked = set_of(names_z(sync_git(r, { "ls-files", "-o", "--exclude-standard", "-z" }))),
  }
end

local function is_config(name) return name:match("^%.prettierrc") or name:match("^prettier%.config%.") or name == ".prettierignore" end

-- The worktree's own config (or a package.json "prettier" key) could load code, so prettier only ever gets the base branch's.
local function write_file(path, text)
  local file = io.open(path, "wb")
  if not file then return end
  file:write(text)
  file:close()
end

local function package_config(r, names, dir)
  if names["package.yaml"] then return nil, true end
  if not names["package.json"] then return nil end
  local package = decode(sync_git(r, { "show", "origin/" .. r.base .. ":package.json" }))
  local config = package and package.prettier
  if type(config) == "string" then return nil, true end
  if type(config) ~= "table" then return nil end
  config.plugins, config.pluginSearchDirs = nil, nil
  local path = dir .. "/.prettierrc.json"
  write_file(path, vim.json.encode(config))
  return path
end

-- Returns nil when the base branch has no prettier config Neovim can use.
local function base_flags(r)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local names = set_of(names_z(sync_git(r, { "ls-tree", "--name-only", "-z", "origin/" .. r.base })))
  local config, unusable = package_config(r, names, dir)
  if unusable then return nil end
  local ignore
  for _, name in ipairs(vim.tbl_filter(is_config, vim.fn.sort(vim.tbl_keys(names)))) do
    local path = dir .. "/" .. name
    write_file(path, sync_git(r, { "show", "origin/" .. r.base .. ":" .. name }))
    if name == ".prettierignore" then
      ignore = path
    else
      config = config or path
    end
  end
  if not config then return nil end
  local flags = { "--config", config }
  if ignore then vim.list_extend(flags, { "--ignore-path", ignore }) end
  return flags
end

local function prune()
  for _, file in ipairs(vim.fn.glob(M.dir .. "/*.log", false, true)) do
    local stat = vim.uv.fs_stat(file)
    if stat and os.time() - stat.mtime.sec > M.keep then os.remove(file) end
  end
end

local function append(path, text)
  local file = io.open(path, "ab")
  if not file then return end
  file:write(text, "\n")
  file:close()
end

local function transcript_line(ai, event)
  if event.type == "text" then return event.text end
  if event.type == "tool" then
    if EDITS[event.name] then return "▸ " .. event.name .. " " .. (event.path or "") end
    if event.name == "Bash" then return "▸ Bash " .. (event.command or "") end
    return "▸ " .. event.name
  end
  if event.type == "tool_error" then return "  ✗ " .. first_line(event.text) end
  if event.type == "result" then
    local denied = vim.tbl_map(function(d) return str(type(d) == "table" and d.tool_name, "?") end, event.denials)
    return string.format(
      "= %s %s · $%.2f%s", event.is_error and "error" or "done", core.clock(os.time() - ai.started), event.cost or 0,
      #denied > 0 and " · denied: " .. table.concat(denied, ", ") or ""
    )
  end
end

local function on_line(r, ai, line)
  local event = M.parse_event(line)
  if not event or r.ai ~= ai then return end
  local text = transcript_line(ai, event)
  if text then append(ai.log, text) end
  local buf = vim.fn.bufnr(ai.log)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then vim.cmd("checktime " .. buf) end
  if event.type == "text" then
    local last = vim.iter(vim.split(event.text, "\n", { plain = true })):rev():find(function(l) return vim.trim(l) ~= "" end)
    if last then ai.last = vim.trim(last) end
  elseif event.type == "tool" and EDITS[event.name] and event.path then
    ai.current = relative(r, event.path)
  elseif event.type == "result" then
    ai.result = event
  end
  if event.type == "text" or event.type == "tool" then changed() end
end

local function hijacked(r) return not fix.dotgit_ok(r) end

-- Returns true when .git is still not the known one, so no git may run in the worktree.
local function fail_hijacked(r)
  local ai = r.ai
  ai.phase, ai.why = "failed", fix.hijack_note(r)
  if ai.proc then kill(r) end
  set(r, { state = "claude" })
  fix.save_state(r)
  return hijacked(r)
end


local function poll(r, ai)
  if r.ai ~= ai or not ai.proc then return end
  if hijacked(r) then return fail_hijacked(r) end
  core.system({ "git", "--no-optional-locks", "ls-files", "-u", "-z" }, r.path, guard(r, function(ok, out)
    if not ok or r.ai ~= ai or not ai.proc then return end
    ai.unmerged = set_of(vim.tbl_map(function(f) return f.path end, fix.parse_stages(out)))
    local resolved, group = 0, nil
    for _, path in ipairs(ai.files) do
      if not ai.unmerged[path] then resolved = resolved + 1 end
    end
    for i, step in ipairs(ai.plan and ai.plan.groups or {}) do
      if not group and vim.iter(step.files):any(function(path) return ai.unmerged[path] end) then group = i end
    end
    ai.resolved, ai.group = resolved, group or (ai.plan and #ai.plan.groups)
    changed()
  end))
end

local function stop_timers(ai)
  for _, key in ipairs({ "poller", "limiter" }) do
    local timer = ai[key]
    if timer then
      timer:stop()
      timer:close()
      ai[key] = nil
    end
  end
end

kill = function(r)
  local ai = r.ai
  local pid = ai.pid
  if not pid then return end
  pcall(vim.uv.kill, -pid, "sigterm")
  local timer = vim.uv.new_timer()
  timer:start(5000, 0, vim.schedule_wrap(function()
    timer:close()
    if ai.pid == pid and ai.proc then pcall(vim.uv.kill, -pid, "sigkill") end
  end))
end

local function pause(r, why)
  local ai = r.ai
  ai.phase, ai.why = "error", why
  ai.want = nil
  set(r, { state = "resolving", step = "review" })
  fix.save_state(r)
end

local function planned(r, ai)
  local replan = ai.plan ~= nil
  local event = ai.result
  local raw = event and M.report_of(event)
  local plan, err = M.plan_of(raw, ai.files)
  if event and event.is_error then plan, err = nil, first_line(event.text) end
  ai.want = nil
  if plan then
    for _, group in ipairs(plan.groups) do
      if group.kind == "format" and ai.fmt then
        group.strategy = string.format("take %s's file; Neovim re-runs prettier with #%d's config", r.base, r.number)
      elseif group.kind == "format" then
        group.kind, group.strategy = "merge", "Claude merges each one (no prettier config on " .. r.base .. ")"
      end
    end
    ai.plan, ai.plan_secs, ai.phase, ai.why, ai.approved = plan, os.time() - ai.started, "plan", nil, nil
    set(r, { state = "plan", step = "plan" })
    return fix.save_state(r)
  end
  local why = "Claude's plan failed: " .. (err or "no result")
  if replan then
    ai.phase, ai.why = "plan", why
    return set(r, { state = "plan", step = "plan" })
  end
  pause(r, why)
end

local function resolved_count(r)
  local open = unmerged_set(r)
  return #vim.tbl_filter(function(path) return not open[path] end, r.ai.files)
end

local function count_edits(r)
  if hijacked(r) and fail_hijacked(r) then return end
  r.ai.edits = resolved_count(r)
end

local function exited(r, ai, obj, leftover)
  stop_timers(ai)
  procs[r] = nil
  ai.proc, ai.pid, ai.ended = nil, nil, os.time()
  if r.ai ~= ai or r.finished then return pump() end
  if leftover ~= "" then on_line(r, ai, leftover) end
  if ai.leaving then return end
  pump()
  ai.exit = obj.code
  if ai.stopping then
    count_edits(r)
    return fix.abort(r)
  end
  if ai.phase == "failed" then return end
  if ai.want == "plan" then return planned(r, ai) end
  check(r)
end

local function spawn(r)
  local ai = r.ai
  local planning = ai.want == "plan"
  local fmt = formatter(r)
  if fmt then fmt.flags = base_flags(r) end
  ai.no_config = fmt ~= nil and fmt.flags == nil
  if ai.no_config then fmt = nil end
  ai.fmt = fmt
  ai.phase = planning and "planning" or "running"
  ai.started, ai.spawned, ai.ended, ai.resolved, ai.total, ai.group = os.time(), now(), nil, 0, #ai.files, nil
  ai.last, ai.current, ai.result, ai.exit, ai.timed_out, ai.stopping, ai.unmerged = nil, nil, nil, nil, nil, nil, nil
  ai.snap = snapshot(r, set_of(ai.files))
  if not ai.before then
    local open = unmerged_set(r)
    local edited = vim.tbl_filter(function(path) return not open[path] end, names_z(sync_git(r, { "diff", "--name-only", "-z" })))
    ai.before = { dirty = set_of(edited), untracked = ai.snap.untracked }
  end
  vim.fn.mkdir(M.dir, "p")
  prune()
  logs = logs + 1
  ai.log = ai.log or string.format("%s/%d-%d-%d.log", M.dir, r.number, os.time(), logs)
  local prompt = planning and plan_prompt(r, fmt) or run_prompt(r)
  append(ai.log, string.format("# %s · #%d · %s\n%s\n---", planning and "plan" or "run", r.number, os.date("%H:%M:%S"), prompt))

  local buffer = ""
  local function on_stdout(_, data)
    if not data then return end
    local lines = vim.split(buffer .. data, "\n", { plain = true })
    buffer = table.remove(lines)
    vim.schedule(function()
      for _, line in ipairs(lines) do on_line(r, ai, line) end
    end)
  end
  local env = {
    GIT_TERMINAL_PROMPT = "0", GIT_EDITOR = "true", GIT_OPTIONAL_LOCKS = "0", GIT_CONFIG_COUNT = "1",
    GIT_CONFIG_KEY_0 = "remote.origin.pushurl", GIT_CONFIG_VALUE_0 = "no-push://claude-may-not-push", GIT_LITERAL_PATHSPECS = "1",
  }
  local ok, proc = pcall(vim.system, argv_of(r, planning), { cwd = r.path, env = env, stdin = prompt, detach = true, stdout = on_stdout }, function(obj)
    vim.schedule(function() exited(r, ai, obj, buffer) end)
  end)
  if not ok then return pause(r, "claude not found on PATH") end
  ai.proc, ai.pid = proc, proc.pid
  procs[r] = ai
  local poller = vim.uv.new_timer()
  poller:start(2000, 2000, vim.schedule_wrap(function() poll(r, ai) end))
  local limiter = vim.uv.new_timer()
  limiter:start(M.limit * 1000, 0, vim.schedule_wrap(function()
    ai.timed_out = true
    kill(r)
  end))
  ai.poller, ai.limiter = poller, limiter
  set(r, { state = "claude", step = planning and "plan" or "run" })
end

pump = function()
  while vim.tbl_count(procs) < M.max_agents and #queue > 0 do
    local r = table.remove(queue, 1)
    if not r.finished and not r.aborting then spawn(r) end
  end
end

local function enqueue(r, want)
  local ai = r.ai
  ai.want, ai.phase, ai.why, ai.stopped, ai.stopping = want, "queued", nil, nil, nil
  queue[#queue + 1] = r
  set(r, { state = "claude", step = want })
  fix.save_state(r)
  pump()
end

-- Checks: git facts first, then the plan's own claims

local function stopped_why(ai)
  if ai.timed_out then return "hit " .. clock_text(M.limit) .. " limit" end
  local event = ai.result
  local detail = "no result"
  if event and event.is_error then
    detail = first_line(event.text)
  elseif ai.exit ~= 0 then
    detail = "exit " .. tostring(ai.exit)
  end
  return "Claude stopped: " .. detail
end

local function offplan(r, path, reason, group)
  local mark = r.marks[path] or { by = "claude" }
  if mark.by == "you" and (mark.at or 0) >= (r.ai.spawned or math.huge) then return end
  r.marks[path] = mark
  mark.unsure = { kind = "offplan", reason = reason, group = group }
end

local function pool(items, limit, work, on_done)
  local index, pending = 0, #items
  if pending == 0 then return on_done() end
  local function launch()
    index = index + 1
    local item = items[index]
    if not item then return end
    work(item, function()
      pending = pending - 1
      if pending == 0 then return on_done() end
      launch()
    end)
  end
  for _ = 1, math.min(limit, pending) do launch() end
end

local function run_async(args, opts, on_done)
  vim.system(args, vim.tbl_extend("force", { text = false }, opts), function(out) vim.schedule(function() on_done(out) end) end)
end

local function diff_counts(expected, actual)
  local added, removed = 0, 0
  for _, hunk in ipairs(vim.diff(expected, actual, { result_type = "indices" })) do
    removed, added = removed + hunk[2], added + hunk[4]
  end
  return added, removed
end

local function check_format(r, group, i, fmt, done)
  local checks = r.ai.checks
  local paths = vim.tbl_filter(function(path) return not (r.marks[path] and (r.marks[path].unsure or r.marks[path].gave_up)) end, group.files)
  if not fmt then
    local why = r.ai.no_config and "no prettier config on " .. r.base or "no formatter"
    checks.groups[i] = { text = "not checked (" .. why .. ") · skim" }
    return done()
  end
  local failure, differ = nil, 0
  pool(paths, 8, function(path, next_path)
    run_async({ "git", "--no-optional-locks", "show", "origin/" .. r.base .. ":" .. path }, { cwd = r.path }, function(base)
      if base.code ~= 0 then
        differ = differ + 1
        offplan(r, path, "not on " .. r.base, i)
        return next_path()
      end
      local args = vim.list_extend({ fmt.bin }, fmt.flags)
      vim.list_extend(args, { "--stdin-filepath", r.path .. "/" .. path })
      run_async(args, { cwd = r.path, stdin = base.stdout }, function(out)
        if out.code ~= 0 then
          failure = failure or first_line(out.stderr)
        else
          local actual = fix.read(r.path .. "/" .. path) or ""
          if actual ~= out.stdout then
            local added, removed = diff_counts(out.stdout, actual)
            differ = differ + 1
            offplan(r, path, string.format("planned formatting only; differs from prettier on %s (+%d −%d)", r.base, added, removed), i)
          end
        end
        next_path()
      end)
    end)
  end, function()
    if failure then
      checks.groups[i] = { text = "not checked (" .. failure .. ") · skim" }
    elseif differ > 0 then
      checks.groups[i] = { ok = false, text = string.format("%d of %d differ from prettier on %s", differ, #paths, r.base) }
    else
      checks.groups[i] = { ok = true, text = "matches prettier on " .. r.base .. " exactly · nothing to read" }
    end
    done()
  end)
end

local function check_reapply(r, group, i)
  local keep_count, missing = 0, false
  for _, path in ipairs(group.files) do
    local mark = r.marks[path]
    if not (mark and (mark.unsure or mark.gave_up)) then
      local content = fix.read(r.path .. "/" .. path) or ""
      for _, line in ipairs(group.keep[path] or {}) do
        keep_count = keep_count + 1
        if not M.present(content, line) then
          missing = true
          offplan(r, path, string.format("#%d's edit didn't re-apply: %s", r.number, vim.fn.strcharpart(vim.trim(line), 0, 40)), i)
        end
      end
    end
  end
  local text = keep_count == 0 and "not checked (plan listed no lines)" or string.format("all %d code lines present · skim", keep_count)
  r.ai.checks.groups[i] = { ok = keep_count > 0 and not missing or nil, text = text }
end

local function check_prettier(r, fmt, done)
  local paths = {}
  local function sure(path) return not (r.marks[path] or {}).unsure end
  for i, group in ipairs(r.ai.plan and r.ai.plan.groups or {}) do
    local checked = group.kind == "reapply" and r.ai.checks.groups[i] ~= nil
    if checked then vim.list_extend(paths, vim.tbl_filter(sure, group.files)) end
  end
  if not fmt or #paths == 0 then return done() end
  local args = vim.list_extend({ fmt.bin }, fmt.flags)
  vim.list_extend(args, { "--check", "--ignore-unknown", "--" })
  run_async(vim.list_extend(args, paths), { cwd = r.path }, function(out)
    local clean = true
    for line in ((out.stdout or "") .. "\n" .. (out.stderr or "")):gmatch("[^\n]+") do
      local path = line:match("^%[warn%] (.+)$")
      if path and vim.tbl_contains(paths, path) then
        clean = false
        offplan(r, path, "not formatted")
      end
    end
    if clean and out.code == 0 then r.ai.checks.fmt = { name = fmt.name, text = "✓ prettier --check clean" } end
    done()
  end)
end

local function report_files(r, report)
  local out = {}
  for _, entry in ipairs(report and list(report.files) or {}) do
    if type(entry) == "table" and type(entry.path) == "string" then out[relative(r, entry.path)] = entry end
  end
  return out
end

local function outside_paths(r, ai, open)
  local known = set_of(ai.files)
  local found = {}
  local now = index_of(sync_git(r, { "ls-files", "-s", "-z" }))
  for path, meta in pairs(now) do
    if ai.snap.index[path] ~= meta then found[path] = true end
  end
  for path in pairs(ai.snap.index) do
    if not now[path] then found[path] = true end
  end
  for _, path in ipairs(names_z(sync_git(r, { "diff", "--name-only", "-z" }))) do
    if not open[path] then found[path] = true end
  end
  for path, hash in pairs(ai.snap.work or {}) do
    if digest(r, path) ~= hash then found[path] = true end
  end
  for _, path in ipairs(names_z(sync_git(r, { "ls-files", "-o", "--exclude-standard", "-z" }))) do
    if not ai.snap.untracked[path] then found[path] = true end
  end
  local paths = vim.tbl_filter(function(path) return not known[path] end, vim.tbl_keys(found))
  table.sort(paths)
  return paths
end

local function conclude(r, interrupted, report)
  local ai = r.ai
  if ai.stopping then
    count_edits(r)
    return fix.abort(r)
  end
  if r.finished or r.aborting then return end
  local event = ai.result
  local handed_open = vim.iter(ai.files):any(function(path) return r.marks[path] and r.marks[path].gave_up end)
  ai.why, ai.stopped = nil, nil
  if interrupted then
    ai.phase, ai.why = "paused", stopped_why(ai)
  elseif report and report.status == "stopped" then
    local stopped = list(report.stopped)
    ai.phase = "stopped"
    ai.stopped = { group = tonumber(stopped.group), reason = str(stopped.reason, ""), suggestion = str(stopped.suggestion) }
  elseif handed_open then
    ai.phase = "gave_up"
  elseif #unsure_paths(r) > 0 then
    ai.phase = "review"
  else
    ai.phase = "done"
  end
  ai.flagged = #unsure_paths(r)
  ai.unchecked, ai.snap = nil, nil
  ai.cost = event and event.cost or ai.cost
  set(r, { state = "resolving", step = "review" })
  fix.save_state(r)
  fix.rescan(r)
end

local function fail_check(r)
  local ai = r.ai
  ai.phase = "failed"
  ai.why = "Claude changed the branch (HEAD moved or the merge ended) · x goes back to " .. r.orig:sub(1, 7)
  set(r, { state = "claude" })
  fix.save_state(r)
end

local function mark_outside(r, open)
  local ai = r.ai
  if ai.snap then
    for _, path in ipairs(outside_paths(r, ai, open)) do
      offplan(r, path, "changed outside the conflicts")
      if not vim.tbl_contains(ai.checks.outside, path) then ai.checks.outside[#ai.checks.outside + 1] = path end
    end
  end
  local handed = set_of(ai.files)
  for _, f in ipairs(r.files) do
    if not handed[f.path] and not open[f.path] and fix.marker_count(fix.read(r.path .. "/" .. f.path) or "") > 0 then
      offplan(r, f.path, "staged with conflict markers")
    end
  end
end

local function mark_left(mark, entry, markers)
  local note = "left unresolved"
  if markers > 0 then note = "markers left" end
  mark.gave_up = entry and str(entry.note) or note
  mark.suggestion = entry and str(entry.suggestion)
end

local function mark_done(r, path, mark, entry)
  mark.note = entry and str(entry.note)
  if entry and entry.result == "unsure" then
    mark.unsure = { kind = "claude", reason = str(entry.note, "unsure"), guess = str(entry.guess), line = tonumber(entry.line), group = M.group_of(r.ai.plan, path) }
  elseif entry and entry.result == "gave_up" then
    offplan(r, path, "reported gave up but left no markers")
  end
end

local function mark_handed(r, open, report, interrupted)
  local reports = report_files(r, report)
  local by_path = {}
  for _, f in ipairs(r.files) do by_path[f.path] = f end
  local finished_ok = not interrupted and not (report and report.status == "stopped")
  local staged = {}
  for _, path in ipairs(r.ai.files) do
    local entry = reports[path]
    local markers = fix.marker_count(fix.read(r.path .. "/" .. path) or "")
    local file = by_path[path]
    local still = open[path] and (markers > 0 or not (file and file.kind == "content"))
    local gave_up = entry ~= nil and entry.result == "gave_up"
    local mark = r.marks[path] or {}
    local settled = not still or finished_ok or gave_up
    if mark.by ~= "you" and settled then
      r.marks[path] = mark
      mark.gave_up, mark.unsure, mark.by = nil, nil, "claude"
      if still then
        mark_left(mark, entry, markers)
      elseif markers > 0 then
        offplan(r, path, "staged with conflict markers")
      else
        staged[#staged + 1] = path
        mark_done(r, path, mark, entry)
      end
    end
  end
  if #staged > 0 then sync_git(r, vim.list_extend({ "add", "-u", "--" }, staged)) end
end

local FORMAT_TIMEOUT = 120000

local function format_errors(paths, out)
  local errors = {}
  local text = (out.stderr or "") .. "\n" .. (out.stdout or "")
  for line in text:gmatch("[^\n]+") do
    local path = line:match("^%[error%] (.-): ")
    if path and vim.tbl_contains(paths, path) and not errors[path] then errors[path] = line end
  end
  return errors
end

-- Formats the resolved files with the base config. Calls on_done(failures): path -> reason, staged only on success.
local function format_resolved(r, open, on_done)
  local fmt = r.ai.fmt
  if not fmt then return on_done({}) end
  local paths = vim.tbl_filter(function(path)
    local mine = (r.marks[path] or {}).by == "you"
    return not open[path] and not mine and fix.marker_count(fix.read(r.path .. "/" .. path) or "") == 0
  end, r.ai.files)
  if #paths == 0 then return on_done({}) end
  local args = vim.list_extend({ fmt.bin }, fmt.flags)
  vim.list_extend(args, { "--write", "--ignore-unknown", "--" })
  run_async(vim.list_extend(args, paths), { cwd = r.path, text = true, timeout = FORMAT_TIMEOUT }, function(out)
    if out.code == 0 then
      sync_git(r, vim.list_extend({ "add", "--" }, paths))
      return on_done({})
    end
    local failures = {}
    for path, line in pairs(format_errors(paths, out)) do failures[path] = "prettier couldn't parse: " .. line end
    if vim.tbl_isempty(failures) then
      local detail = first_line(out.stderr)
      if detail == "" then detail = "exit " .. out.code end
      local why = "prettier failed: " .. detail
      if out.code == 124 then why = "prettier timed out" end
      for _, path in ipairs(paths) do failures[path] = why end
    end
    on_done(failures)
  end)
end

local function plan_checks(r, on_done)
  local ai = r.ai
  if not ai.plan then return on_done() end
  local handed = set_of(ai.files)
  local formats = {}
  for i, group in ipairs(ai.plan.groups) do
    local mine = vim.tbl_filter(function(path) return handed[path] end, group.files)
    if #mine > 0 then
      local scoped = vim.tbl_extend("force", group, { files = mine })
      if group.kind == "format" then
        formats[#formats + 1] = { scoped, i }
      elseif group.kind == "reapply" then
        check_reapply(r, scoped, i)
      end
    end
  end
  pool(formats, 1, function(item, done) check_format(r, item[1], item[2], ai.fmt, done) end, on_done)
end

check = function(r)
  local ai = r.ai
  if hijacked(r) then return fail_hijacked(r) end
  ai.phase = "checking"
  changed()
  if vim.trim(sync_git(r, { "rev-parse", "HEAD" })) ~= r.orig or not exists(r.gitdir .. "/MERGE_HEAD") then return fail_check(r) end
  r.marks = r.marks or {}
  ai.checks = ai.checks or { groups = {}, outside = {} }
  local event = ai.result
  local report = event and M.report_of(event)
  local errored = event ~= nil and event.is_error
  local exited_badly = ai.exit ~= nil and (ai.exit ~= 0 or not event)
  local interrupted = ai.timed_out or errored or exited_badly
  local open = unmerged_set(r)
  mark_outside(r, open)
  format_resolved(r, open, function(failures)
    if r.ai ~= ai or r.finished or r.aborting then return end
    mark_handed(r, open, report, interrupted)
    for path, why in pairs(failures) do offplan(r, path, why) end
    plan_checks(r, function()
      if ai.stopping or r.finished or r.aborting then return conclude(r, interrupted, report) end
      check_prettier(r, ai.fmt, function() conclude(r, interrupted, report) end)
    end)
  end)
end

-- Flows

local function start_with(r, files)
  local ai = r.ai or {}
  if #files == 0 then
    if not ai.unchecked then return fix.rescan(r) end
    ai.result, ai.exit, ai.timed_out = nil, nil, nil
    set(r, { state = "claude", step = "run" })
    return check(r)
  end
  r.ai, r.marks = ai, r.marks or {}
  ai.all = ai.all or {}
  for _, path in ipairs(files) do
    if not vim.tbl_contains(ai.all, path) then ai.all[#ai.all + 1] = path end
  end
  ai.files = files
  if ai.plan and not ai.approved then
    ai.phase = "plan"
    set(r, { state = "plan", step = "plan" })
    return fix.save_state(r)
  end
  enqueue(r, #files >= M.plan_at and not ai.plan and "plan" or "run")
end

function M.start(r, file)
  if r.state ~= "resolving" or r.busy or r.scanning or r.stacked then return false end
  if file then
    start_with(r, { file.path })
    return true
  end
  fix.accept_all(r, function()
    start_with(r, vim.tbl_map(function(f) return f.path end, M.unresolved(r)))
  end)
  return true
end

function M.start_item(m, item)
  local r = fix.start(m, item)
  if not item.onto then
    r.ai_wanted = true
    changed()
  end
  return r
end

function M.start_pr(dir, pr)
  return M.start_item({ dir = dir }, { number = pr.number, title = pr.title, branch = pr.headRefName, base = pr.baseRefName, fix = pr._fix })
end

function M.run(r)
  if r.state ~= "plan" then return end
  r.ai.approved = true
  enqueue(r, "run")
end

function M.strategy(r)
  local ai = r.ai
  if not M.wants_strategy(r) then return end
  local suggestions = {}
  for _, f in ipairs(M.unresolved(r)) do
    local suggestion = (r.marks[f.path] or {}).suggestion
    if suggestion then suggestions[#suggestions + 1] = suggestion end
  end
  local default = (ai.stopped and ai.stopped.suggestion) or table.concat(suggestions, "; ")
  vim.ui.input({ prompt = "Change strategy: ", default = default }, function(text)
    if not text or vim.trim(text) == "" or r.ai ~= ai then return end
    ai.note = ai.note and (ai.note .. "; " .. vim.trim(text)) or vim.trim(text)
    if r.state == "plan" then return enqueue(r, "plan") end
    M.start(r)
  end)
end

function M.decline(r)
  if r.state ~= "plan" then return end
  r.ai = nil
  set(r, { state = "resolving", step = "resolve" })
  fix.save_state(r)
end

function M.stop(r)
  local ai = r.ai
  if not ai or r.state ~= "claude" then return end
  if ai.phase == "queued" then
    queue = vim.tbl_filter(function(item) return item ~= r end, queue)
    return fix.abort(r)
  end
  if ai.proc then
    ai.stopping = true
    return kill(r)
  end
  if ai.phase == "checking" then
    ai.stopping = true
    return
  end
  fix.abort(r)
end

function M.accept(r, path)
  local mark = r.marks and r.marks[path]
  if not mark or not mark.unsure or r.state ~= "resolving" or r.busy then return end
  local markers = fix.marker_count(fix.read(r.path .. "/" .. path) or "")
  if markers > 0 then return vim.notify(string.format("%s still has %d conflict markers", path, markers), vim.log.levels.WARN) end
  mark.unsure, mark.by = nil, "you"
  core.system({ "git", "add", "--", path }, r.path, guard(r, function()
    fix.save_state(r)
    fix.rescan(r)
  end), LITERAL)
end

local function first_marker(r, path)
  local lnum = 1
  for line in (fix.read(r.path .. "/" .. path) or ""):gmatch("[^\n]*\n?") do
    if line:match("^<<<<<<<+ ") then return lnum end
    lnum = lnum + 1
  end
  return 1
end

local function review_order(r, scope)
  if type(scope) == "table" then return scope end
  if type(scope) == "number" then return r.ai.plan.groups[scope].files end
  local paths = unsure_paths(r)
  local seen = set_of(paths)
  local function add(path)
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  for _, f in ipairs(r.files) do
    if (r.marks[f.path] or {}).gave_up and (f.status == "real" or f.status == "ready") then add(f.path) end
  end
  vim.tbl_map(add, M.merge_paths(r))
  for _, group in ipairs(r.ai.plan and r.ai.plan.groups or {}) do
    if group.kind == "reapply" then vim.tbl_map(add, group.files) end
  end
  return paths
end

function M.quickfix(r, scope)
  local paths = review_order(r, scope)
  if #paths == 0 then return end
  local items = {}
  for _, path in ipairs(paths) do
    local mark = (r.marks or {})[path] or {}
    local icon = M.mark_of(r, path)
    local note = mark.unsure and mark.unsure.reason or mark.gave_up or mark.note or ""
    items[#items + 1] = {
      filename = r.path .. "/" .. path, lnum = mark.unsure and mark.unsure.line or first_marker(r, path), text = vim.trim(icon .. " " .. note),
    }
  end
  require("config.merges").close()
  vim.fn.setqflist({}, " ", { title = "review #" .. r.number, items = items })
  vim.cmd("silent cc 1")
end

function M.transcript(r, path)
  local log = r.ai and r.ai.log
  if not log or not exists(log) then return end
  require("config.merges").close()
  vim.cmd("botright split " .. vim.fn.fnameescape(log))
  vim.cmd("setlocal autoread")
  vim.cmd("normal! G")
  if path then vim.fn.search("\\V" .. vim.fn.escape(path, "\\"), "bW") end
end

function M.diff_text(r)
  local unsure = unsure_paths(r)
  local seen = set_of(unsure)
  local rest = vim.tbl_filter(function(path) return not seen[path] end, names_z(sync_git(r, { "diff", "--name-only", "-z", r.orig })))
  local out = {}
  for _, paths in ipairs({ unsure, rest }) do
    if #paths > 0 then out[#out + 1] = sync_git(r, vim.list_extend({ "diff", r.orig, "--" }, paths)) end
  end
  return table.concat(out, "\n")
end

-- Autocmds

local group = vim.api.nvim_create_augroup("PrAi", { clear = true })

local STARTED = { queued = true, planning = true, running = true, checking = true }

vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "PrMergesChanged",
  callback = function()
    for _, r in ipairs(review.merges) do
      if r.kind == "fix" and not r.finished then
        if r.ai_wanted and r.state == "resolving" and r.scanned and not r.busy then
          r.ai_wanted = nil
          M.start(r)
        elseif r.ai_wanted and (r.state == "ready" or r.state == "failed") then
          r.ai_wanted = nil
        end
        local ai = r.ai
        if ai and r.state == "paused" and STARTED[ai.phase] then
          ai.phase, ai.why, ai.unchecked = "paused", "Neovim closed during the run", true
        end
        if ai and ai.phase == "failed" and r.state ~= "claude" then
          set(r, { state = "claude" })
        elseif ai and ai.phase == "plan" and r.state == "resolving" then
          set(r, { state = "plan", step = "plan" })
        end
        local all_given_back = ai and r.state == "resolving" and ai.phase == "gave_up" and #gave_up_paths(r) == 0
        if all_given_back then ai.phase = #unsure_paths(r) > 0 and "review" or "done" end
      end
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(args)
    local file = vim.fs.normalize(vim.api.nvim_buf_get_name(args.buf))
    for _, r in ipairs(review.merges) do
      if r.kind == "fix" and not r.finished and r.marks and r.path and vim.startswith(file, r.path .. "/") then
        local path = file:sub(#r.path + 2)
        local mark = r.marks[path]
        if mark then
          mark.by, mark.at = "you", now()
          local clean = fix.marker_count(fix.read(file) or "") == 0
          if clean and r.state == "resolving" then
            vim.system({ "git", "add", "--", path }, { cwd = r.path, env = LITERAL }):wait()
            mark.unsure, mark.gave_up = nil, nil
          end
          fix.save_state(r)
        end
      end
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    queue = {}
    local pids = {}
    for _, r in ipairs(review.merges) do
      local ai = r.ai
      if r.kind == "fix" and not r.finished and ai and r.state == "claude" and ai.phase ~= "failed" then
        ai.leaving = true
        if ai.pid then
          pids[#pids + 1] = ai.pid
          pcall(vim.uv.kill, -ai.pid, "sigterm")
        end
        local started = STARTED[ai.phase] and ai.phase ~= "queued"
        ai.phase, ai.why, ai.unchecked = "paused", "Neovim closed during the run", started or nil
        fix.save_state(r)
      end
    end
    for _, pid in ipairs(pids) do
      vim.wait(1000, function() return vim.uv.kill(-pid, 0) ~= 0 end, 20)
      pcall(vim.uv.kill, -pid, "sigkill")
    end
  end,
})

pcall(prune)

return M
