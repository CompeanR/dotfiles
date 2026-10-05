#!/usr/bin/env bash
# AI conflict fix of nvim/lua/config/pr_ai.lua: pure helpers, then the runner, checks,
# marks and dashboard against temp git repos with a fake `claude`, `gh` and prettier.
# The real Claude CLI is never invoked and nothing touches a real remote.
set -euo pipefail

tmp=$(cd "$(mktemp -d)" && pwd -P)
cleanup() {
  for _ in 1 2 3 4 5; do
    rm -rf "$tmp" 2>/dev/null && return
    sleep 0.5
  done
}
trap cleanup EXIT

cat > "$tmp/unit.lua" <<'LUA'
local ai = require("config.pr_ai")

local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\n")
    vim.cmd("cquit 1")
  end
end

local function assistant(block) return vim.json.encode({ type = "assistant", message = { content = { block } } }) end

local text = ai.parse_event(assistant({ type = "text", text = "a.ts: merging" }))
expect(text.type == "text" and text.text == "a.ts: merging", "text event")
local edit = ai.parse_event(assistant({ type = "tool_use", name = "Edit", input = { file_path = "/w/a.ts" } }))
expect(edit.type == "tool" and edit.name == "Edit" and edit.path == "/w/a.ts", "edit event")
local bash = ai.parse_event(assistant({ type = "tool_use", name = "Bash", input = { command = "git add -- a.ts" } }))
expect(bash.type == "tool" and bash.command == "git add -- a.ts", "bash event")
local failed = ai.parse_event(vim.json.encode({ type = "user", message = { content = { { type = "tool_result", is_error = true, content = "denied\nmore" } } } }))
expect(failed.type == "tool_error" and failed.text == "denied\nmore", "tool error event")
local result = ai.parse_event(vim.json.encode({ type = "result", is_error = false, result = "ok", structured_output = { status = "done" }, total_cost_usd = 0.12 }))
expect(result.type == "result" and result.structured.status == "done" and result.cost == 0.12 and not result.is_error, "result event")
expect(ai.parse_event("not json") == nil and ai.parse_event("42") == nil and ai.parse_event("") == nil, "garbage lines")

expect(ai.report_of(result).status == "done", "structured output wins")
local fenced = { type = "result", text = 'done\n```json\n{"status":"stopped"}\n```\nbye' }
expect(ai.report_of(fenced).status == "stopped", "fenced json fallback")
expect(ai.report_of({ type = "result", text = '{"status":"done"}' }).status == "done", "whole text fallback")
expect(ai.report_of({ type = "result", text = "no json here" }) == nil, "no report")

local files = { "a", "b", "c", "d" }
local plan = ai.plan_of({
  summary = "safe", minutes = 3,
  groups = {
    { title = "fmt", strategy = "prettier", kind = "format", files = { "a", "zzz" } },
    { title = "dup", strategy = "x", kind = "merge", files = { "a" } },
    { title = "bad", strategy = "x", kind = "wat", files = { "b" } },
    { title = "re", strategy = "reapply", kind = "reapply", files = { "b" }, keep = { { path = "b", lines = { "let x = 1" } }, { path = "zzz", lines = { "q" } } } },
  },
}, files)
expect(#plan.groups == 3, "unknown paths dropped, duplicate and bad kind groups dropped: " .. #plan.groups)
expect(vim.deep_equal(plan.groups[1].files, { "a" }), "first group wins the duplicate")
expect(vim.deep_equal(plan.groups[2].keep, { b = { "let x = 1" } }), "keep lines kept for listed files only")
expect(plan.groups[3].title == "not in the plan" and plan.groups[3].kind == "merge" and vim.deep_equal(plan.groups[3].files, { "c", "d" }), "missing files get a final group")
expect(plan.summary == "safe" and plan.minutes == 3, "summary and minutes")
local none, why = ai.plan_of({ groups = {} }, files)
expect(none == nil and why == "empty plan", "empty plan")
expect(ai.plan_of({ groups = { { title = "x", strategy = "y", kind = "merge", files = { "nope" } } } }, files) == nil, "only unknown files is an empty plan")
expect(ai.plan_of("garbage", files) == nil, "non-table plan")

expect(ai.present("function  foo(a,\n    b) {\n  return 1\n}", "foo(a, b) { return 1 }"), "present ignores whitespace and wrapping")
expect(not ai.present("foo(a, b)", "foo(a, c)"), "present finds differences")

local function rec(number, state, fields)
  return vim.tbl_extend("force", { kind = "fix", number = number, state = state, ai = {}, files = {}, marks = {} }, fields or {})
end
local function running(number, phase, extra) return rec(number, "claude", { ai = vim.tbl_extend("force", { phase = phase }, extra or {}) }) end
local function plan_of_three() return { groups = { {}, {}, {} } } end

expect(ai.status_text({}) == nil and ai.status_text({ { kind = "fix", number = 1, state = "resolving" } }) == nil, "no ai records")
local s = ai.status_text({ rec(57, "plan", { ai = { phase = "plan" } }), running(62, "running", { resolved = 1, total = 4 }) })
expect(s == "◆1 · #57 plan ready", "plan ready: " .. tostring(s))
s = ai.status_text({ running(57, "running", { plan = plan_of_three(), group = 2 }), running(62, "running"), running(63, "queued") })
expect(s == "◆2 +1 queued · #57 plan 2/3", "running: " .. tostring(s))
s = ai.status_text({ rec(57, "ready", { ai = { phase = "done" } }), running(63, "running", { resolved = 6, total = 17 }) })
expect(s == "◆1 · #57 ready to push", "ready: " .. tostring(s))
s = ai.status_text({
  rec(57, "resolving", { ai = { phase = "review" }, marks = { a = { unsure = {} }, b = { unsure = {} }, c = { unsure = {} }, d = { by = "claude" } } }),
  running(63, "running"),
})
expect(s == "◆1 · #57 3 unsure", "unsure: " .. tostring(s))
s = ai.status_text({ rec(57, "resolving", { ai = { phase = "gave_up" } }), rec(62, "resolving", { ai = { phase = "paused" } }) })
expect(s == "◆ #57 gave up · #62 paused", "attention: " .. tostring(s))
s = ai.status_text({ running(57, "running", { resolved = 3, total = 10 }) })
expect(s == "◆1 · #57 3/10", "no plan progress: " .. tostring(s))
s = ai.status_text({ rec(57, "resolving", { ai = { phase = "stopped", stopped = { group = 2 } } }) })
expect(s == "◆ #57 step 2 stopped", "stopped: " .. tostring(s))

expect(ai.label(rec(57, "claude", { ai = { phase = "failed" } })) == "failed", "failed label")
expect(ai.label(rec(57, "resolving", { ai = { phase = "done", resolved = 3, total = 4 } })) == "ready to push", "done label has no progress")
expect(ai.label(rec(57, "paused", { ai = { phase = "plan", plan = plan_of_three(), group = 1 } })) == "plan ready", "restored plan label")
expect(ai.label(rec(57, "claude", { ai = { phase = "running", resolved = 3, total = 4 } })) == "3/4", "running label")
expect(ai.label(rec(57, "resolving", { ai = { phase = "done" }, marks = { a = { gave_up = "markers left" } } })) == "gave up", "a held record never reads ready to push")
expect(ai.label(rec(57, "resolving", { ai = { phase = "done" }, marks = { a = { unsure = {} } } })) == "1 unsure", "unsure marks hold the label")

print("unit ok")
vim.cmd("qa!")
LUA

nvim --headless "+luafile $tmp/unit.lua" +cquit 2>&1

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email "pr-ai-test@example.com"
git config --global user.name "PR AI Test"
git config --global init.defaultBranch master
git config --global core.editor true
git config --global merge.ff only
git config --global pull.rebase true

cd "$tmp"
git init -q --bare remote.git
git clone -q remote.git main 2>/dev/null
cd main

printf '%s\n' 1 2 3 4 5 6 > easy.txt
printf '%s\n' a b c > real.txt
printf '%s\n' x y z > real2.txt
printf '%s\n' o > outside.txt
printf 'function f() {\n  return 1\n}\n' > fmt1.ts
printf 'function g() {\n  return 1\n}\n' > fmt2.ts
printf 'const a = 1\nconst b = 2\nconst c = 3\n' > re.ts
printf 'export const k = 1\nexport const m = 2\n' > logic.ts
echo one > 'g[1].txt'
echo two > g1.txt
echo 'node_modules/' > .gitignore
echo '{ "useTabs": false }' > .prettierrc
git add -A
git commit -qm "Initial"
git push -q origin master
base=$(git rev-parse HEAD)

branch() { git checkout -q -b "$1" "$base"; }
publish() {
  git commit -qam "$1"
  git push -q origin HEAD
}

branch feat/push
perl -pi -e 's/^2$/mine2/' easy.txt
perl -pi -e 's/^b$/mine/' real.txt
publish "feat: push"

branch feat/a
perl -pi -e 's/^2$/mine2/' easy.txt
perl -pi -e 's/^b$/mine/' real.txt
perl -pi -e 's/^y$/mine/' real2.txt
publish "feat: a"

branch feat/plan
printf 'function f() {\n\treturn 1\n}\n' > fmt1.ts
printf 'function g() {\n\treturn 1\n}\n' > fmt2.ts
perl -pi -e 's/^const b = 2$/const b = 20/' re.ts
perl -pi -e 's/^export const m = 2$/export const m = 22/' logic.ts
publish "feat: plan"

for name in q1 q2 entry; do
  branch "feat/$name"
  perl -pi -e 's/^b$/mine/' real.txt
  publish "feat: $name"
done

git checkout -q master
perl -pi -e 's/^3$/theirs3/' easy.txt
perl -pi -e 's/^b$/theirs/' real.txt
perl -pi -e 's/^y$/theirs/' real2.txt
perl -pi -e 's/return 1/return 2/' fmt1.ts fmt2.ts
perl -pi -e 's/^const b = 2$/const b = 3/' re.ts
perl -pi -e 's/^export const m = 2$/export const m = 3/' logic.ts
publish "Change things (#54)"

mkdir "$tmp/main-wt"
for name in push a plan q1 q2 entry; do git worktree add -q "$tmp/main-wt/$name" "feat/$name"; done

mkdir -p node_modules/.bin
cat > node_modules/.bin/prettier <<'PY'
#!/usr/bin/env python3
import json, os, re, sys

with open(os.environ["FAKE_PRETTIER_LOG"], "a") as log:
    log.write(json.dumps(sys.argv) + "\n")

def fmt(text):
    return "\n".join(re.sub(r"[ \t]+$", "", line.replace("\t", "  ")) for line in text.split("\n"))

args = sys.argv[1:]
if "--stdin-filepath" in args:
    sys.stdout.write(fmt(sys.stdin.read()))
elif "--write" in args:
    failed = False
    for path in args[args.index("--write") + 1:]:
        if path.startswith("--"):
            continue
        text = open(path).read()
        if "CRASH" in text:
            print("boom", file=sys.stderr)
            sys.exit(1)
        if "SYNTAX ERROR" in text:
            print("[error] " + path + ": SyntaxError: bad input (1:1)", file=sys.stderr)
            failed = True
            continue
        open(path, "w").write(fmt(text))
    sys.exit(2 if failed else 0)
elif "--check" in args:
    bad = [path for path in args[args.index("--") + 1:] if fmt(open(path).read()) != open(path).read()]
    for path in bad:
        print("[warn] " + path, file=sys.stderr)
    sys.exit(1 if bad else 0)
PY
chmod +x node_modules/.bin/prettier
mkdir -p "$tmp/main-wt/push/node_modules/.bin"
cp node_modules/.bin/prettier "$tmp/main-wt/push/node_modules/.bin/prettier"
cd "$tmp"

git init -q evil
(cd evil && echo x > f && git add f && git commit -qm x)
printf '#!/bin/sh\ntouch "%s/fsmonitor-ran"\n' "$tmp" > fsmonitor.sh
chmod +x fsmonitor.sh
git -C evil config core.fsmonitor "$tmp/fsmonitor.sh"

mkdir bin
cat > bin/claude <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time

argv = sys.argv[1:]
prompt = sys.stdin.read()

def log(entry):
    with open(os.environ["FAKE_CLAUDE_LOG"], "a") as out:
        out.write(json.dumps(entry) + "\n")

log({"kind": "call", "argv": argv, "cwd": os.getcwd(), "prompt": prompt, "t": time.time()})
with open(os.environ["FAKE_CLAUDE_PID"], "w") as out:
    out.write(str(os.getpid()))

tools = argv[argv.index("--tools") + 1].split(",")
mode = "run" if "Edit" in tools else "plan"
scenario = json.load(open(os.environ["FAKE_CLAUDE_SCENARIO"])).get(mode, {})

def emit(event):
    print(json.dumps(event), flush=True)

def assistant(block):
    emit({"type": "assistant", "message": {"content": [block]}})

emit({"type": "system", "subtype": "init"})
for step in scenario.get("steps", []):
    path = step["path"]
    assistant({"type": "text", "text": path + ": " + step.get("line", "resolving")})
    assistant({"type": "tool_use", "name": "Edit", "input": {"file_path": os.getcwd() + "/" + path}})
    with open(path, "w") as out:
        out.write(step["content"])
    if step.get("stage", True):
        subprocess.run(["git", "add", "--", path], check=True)
    emit({"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}})
    time.sleep(step.get("sleep", 0))
for path, content in scenario.get("outside", {}).items():
    with open(path, "w") as out:
        out.write(content)
if scenario.get("commit"):
    subprocess.run(["git", "commit", "-qm", "claude commit", "--no-edit"], check=True)
if scenario.get("push"):
    code = subprocess.run(["git", "push", "origin", "HEAD"], capture_output=True).returncode
    log({"kind": "push", "exit": code})
time.sleep(scenario.get("sleep_end", 0))
result = {"type": "result", "subtype": "success", "is_error": scenario.get("is_error", False), "total_cost_usd": 0.12}
report = scenario.get("report")
if scenario.get("fenced"):
    result["result"] = "done\n```json\n" + json.dumps(report) + "\n```"
else:
    result["result"] = scenario.get("text", "done")
    if report is not None:
        result["structured_output"] = report
emit(result)
sys.exit(scenario.get("exit", 0))
PY
chmod +x bin/claude

cat > bin/gh <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time

args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")

if args[:2] == ["pr", "view"]:
    branch = json.loads(os.environ["FAKE_GH_BRANCHES"])[args[2]]
    head = subprocess.check_output(["git", "--git-dir", os.environ["FAKE_GH_REMOTE"], "rev-parse", "refs/heads/" + branch], text=True).strip()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    check = {"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": now, "completedAt": now,
             "detailsUrl": "https://ci.example/run/1"}
    print(json.dumps({"number": int(args[2]), "headRefOid": head, "isDraft": False, "statusCheckRollup": [check]}))
elif args[:2] == ["pr", "checks"]:
    pass
else:
    sys.exit("fake gh: unhandled " + " ".join(args))
PY
chmod +x bin/gh

export TMP="$tmp"
export FAKE_GH_LOG="$tmp/gh.log" FAKE_GH_REMOTE="$tmp/remote.git"
export FAKE_GH_BRANCHES='{"70":"feat/push","71":"feat/a","72":"feat/plan","73":"feat/q1","74":"feat/q2","80":"feat/entry"}'
export FAKE_PRETTIER_LOG="$tmp/prettier.log"
export FAKE_CLAUDE_LOG="$tmp/claude.log" FAKE_CLAUDE_PID="$tmp/claude.pid" FAKE_CLAUDE_SCENARIO="$tmp/scenario.json"
touch "$tmp/gh.log" "$tmp/claude.log" "$tmp/prettier.log"
echo '{}' > "$tmp/scenario.json"

cat > "$tmp/test.lua" <<'LUA'
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
vim.fn.confirm = function() error("confirm must not be called") end
vim.ui.input = function() error("vim.ui.input must be stubbed") end
vim.o.columns, vim.o.lines = 170, 50

local review = require("config.review_pr")
local fix = require("config.pr_fix")
local pr_ai = require("config.pr_ai")
local merges = require("config.merges")
review.settle_ms = 100

local tmp = vim.env.TMP
local main, remote = tmp .. "/main", tmp .. "/remote.git"
pr_ai.dir = tmp .. "/ai-logs"

local function git(dir, ...)
  local out = vim.system(vim.list_extend({ "git" }, { ... }), { cwd = dir, text = true }):wait()
  return vim.trim(out.stdout or ""), out.code
end
local function calls()
  local out = {}
  for _, line in ipairs(vim.fn.readfile(vim.env.FAKE_CLAUDE_LOG)) do
    local entry = vim.json.decode(line)
    if entry.kind == "call" then out[#out + 1] = entry end
  end
  return out
end
local function pushes()
  local out = {}
  for _, line in ipairs(vim.fn.readfile(vim.env.FAKE_CLAUDE_LOG)) do
    local entry = vim.json.decode(line)
    if entry.kind == "push" then out[#out + 1] = entry.exit end
  end
  return out
end
local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\nnotes:\n" .. table.concat(notes, "\n") .. "\n")
    vim.cmd("cquit 1")
  end
end
local function wait(cond, what, ms)
  if vim.wait(ms or 20000, cond, 50) then return end
  expect(false, "timeout: " .. (type(what) == "function" and what() or what))
end
local function remote_sha(branch) return (git(remote, "rev-parse", "refs/heads/" .. branch)) end
local function read(path) return table.concat(vim.fn.readfile(path), "\n") end
local function buffer() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
local function scenario(tbl) vim.fn.writefile({ vim.json.encode(tbl) }, vim.env.FAKE_CLAUDE_SCENARIO) end
local function has(list, value) return vim.tbl_contains(list, value) end
local function alive(pid) return vim.uv.kill(pid, 0) == 0 end
local function phase(r) return r.ai and r.ai.phase end
local function claude_pid() return tonumber(read(vim.env.FAKE_CLAUDE_PID)) end
local function tree_ok(path, head)
  expect((git(path, "rev-parse", "HEAD")) == head, path .. " HEAD unchanged")
  expect((git(path, "status", "--porcelain")) == "", path .. " clean")
  expect(select(2, git(path, "rev-parse", "-q", "--verify", "MERGE_HEAD")) ~= 0, path .. " no MERGE_HEAD")
end
local function view_of(r)
  merges.open(r)
  vim.wait(150)
  return buffer()
end
local function goto_line(pattern)
  vim.cmd("normal! gg")
  expect(vim.fn.search(pattern, "W") > 0, "row " .. pattern .. " in\n" .. buffer())
end
local function undo(r)
  fix.abort(r)
  wait(function() return r.finished end, "#" .. r.number .. " undone (" .. r.state .. " " .. tostring(r.detail) .. " aborting=" .. tostring(r.aborting) .. " busy=" .. tostring(r.busy) .. " pending=" .. tostring(r.abort_pending) .. ")")
  tree_ok(r.path, r.orig)
end

local function item(number, branch)
  return { number = number, icon = "✗", hl = "PrRed", text = "x", branch = branch, base = "master", title = "PR " .. number, fix = "cmd" }
end
local items = { [70] = item(70, "feat/push"), [71] = item(71, "feat/a"), [72] = item(72, "feat/plan"), [73] = item(73, "feat/q1"), [74] = item(74, "feat/q2"), [80] = item(80, "feat/entry") }
local merged = { dir = main, number = 54, title = "Change things", state = "merged", started = os.time(), finished = os.time(), fallout = { items[80] } }
table.insert(review.merges, 1, merged)

local function resolving(number)
  local r = fix.start(merged, items[number])
  wait(function() return r.state == "resolving" and not r.busy end, "#" .. number .. " resolving")
  return r
end
local function start_claude(r)
  view_of(r)
  vim.cmd("normal c")
end

expect(vim.fn.exepath("claude") == tmp .. "/bin/claude", "the fake claude shadows the real CLI: " .. vim.fn.exepath("claude"))
local old_log = pr_ai.dir .. "/old.log"
vim.fn.mkdir(pr_ai.dir, "p")
vim.fn.writefile({ "old" }, old_log)
vim.uv.fs_utime(old_log, os.time() - 25 * 3600, os.time() - 25 * 3600)

local report = function(files, extra) return vim.tbl_extend("force", { status = "done", files = files }, extra or {}) end
local resolved_real = { path = "real.txt", content = "a\nresolved\nc\n", line = "merging real" }
local resolved_real2 = { path = "real2.txt", content = "x\nresolved2\nz\n", line = "merging real2" }

-- 1. small PR, no plan, easy proposals are accepted first
local wt70 = tmp .. "/main-wt/push"
local r70 = resolving(70)
local branch_before = remote_sha("feat/push")
local text = view_of(r70)
expect(text:find("c: let Claude resolve the 2", 1, true) and text:find("Runs claude -p in", 1, true), "intro box\n" .. text)
expect(not text:find("Plans first", 1, true), "small fixes do not plan first")
scenario({ run = { steps = { vim.tbl_extend("force", resolved_real, { note = "x" }) }, push = true, report = report({ { path = "real.txt", result = "resolved", note = "kept master's value, your name" } }) } })
vim.cmd("normal c")
wait(function() return r70.state == "ready" end, "#70 ready")
expect(r70.marks["easy.txt"].by == "easy" and r70.files[1].status == "accepted", "easy file accepted first")
local call = calls()[1]
local argv = call.argv
for _, arg in ipairs({ "-p", "--verbose", "--no-session-persistence", "--strict-mcp-config", "--json-schema", "Bash(git push:*)", "Bash(git commit:*)", "Edit(/" .. wt70 .. "/**)", "Read(/" .. wt70 .. "/**)" }) do
  expect(has(argv, arg), "argv has " .. arg .. "\n" .. vim.inspect(argv))
end
local function after(flag) return argv[vim.fn.index(argv, flag) + 2] end
expect(after("--output-format") == "stream-json" and after("--permission-mode") == "dontAsk" and after("--settings") == '{"disableAllHooks":true}', "argv flag values")
expect(not has(argv, "--model") and not has(argv, "--max-budget-usd"), "no model or budget flag by default")
expect(not vim.iter(argv):any(function(a) return a:find("install", 1, true) or a:find("npm", 1, true) end), "no install rules")
expect(call.cwd == wt70, "claude runs in the worktree: " .. call.cwd)
expect(call.prompt:find("\nreal.txt", 1, true) and not call.prompt:find("easy.txt", 1, true), "prompt lists only the real file\n" .. call.prompt)
expect(call.prompt:find("mattpocock-skills:resolving-merge-conflicts", 1, true), "prompt names the skill")
expect(call.prompt:find("Never commit, push", 1, true), "prompt forbids commit and push")
expect(not call.prompt:find("node_modules/.bin/prettier", 1, true) and call.prompt:find("any formatter (prettier or others)", 1, true), "the prompt says not to format")
expect(#pushes() == 1 and pushes()[1] ~= 0, "claude's own push failed: " .. vim.inspect(pushes()))
expect(remote_sha("feat/push") == branch_before, "remote untouched by claude")
expect((git(wt70, "rev-list", "--parents", "-n1", "HEAD")) == table.concat({ r70.merge_sha, r70.orig, (git(wt70, "rev-parse", "origin/master")) }, " "), "merge commit parents")
text = view_of(r70)
for _, expected in ipairs({ "= 1 easy  ◆ 1 Claude  ✎ 0 you  ? 0 unsure", "kept master's value, your name", "Merge commit", "Claude used $0.12" }) do
  expect(text:find(expected, 1, true), "ready view shows " .. expected .. "\n" .. text)
end
expect(merges.statusline() == "◆ #70 ready to push", "statusline: " .. merges.statusline())
expect(remote_sha("feat/push") == branch_before, "no push until p")
vim.cmd("normal p")
wait(function() return r70.state == "fixed" end, "#70 fixed")
expect(remote_sha("feat/push") == (git(wt70, "rev-parse", "HEAD")), "pushed by p")
vim.cmd("normal q")
expect(not vim.uv.fs_stat(old_log), "stale transcripts are pruned on spawn")

-- 2. Claude says unsure
local wt71 = tmp .. "/main-wt/a"
local r71 = resolving(71)
pr_ai.model = "x"
scenario({
  run = {
    steps = { resolved_real, resolved_real2 },
    report = report({
      { path = "real.txt", result = "resolved", note = "took master's" },
      { path = "real2.txt", result = "unsure", note = "can't run the migration check", guess = "keep both, master first", line = 2 },
    }),
  },
})
start_claude(r71)
wait(function() return r71.ai and r71.ai.phase == "review" end, "#71 review")
pr_ai.model = nil
argv = calls()[2].argv
expect(has(argv, "--model") and argv[vim.fn.index(argv, "--model") + 2] == "x", "model flag when set")
expect(r71.state == "resolving" and vim.uv.fs_stat(r71.gitdir .. "/MERGE_HEAD") ~= nil, "merge still in progress")
fix.push(r71, false)
expect(r71.state == "resolving", "p is locked while unsure files remain")
text = view_of(r71)
for _, expected in ipairs({ "? real2.txt", "Claude says unsure: can't run the migration check", "guess keep both, master first", "? 1 unsure", "review 0/1" }) do
  expect(text:find(expected, 1, true), "review view shows " .. expected .. "\n" .. text)
end
expect(merges.statusline() == "◆ #71 1 unsure", "statusline: " .. merges.statusline())
goto_line("^  ? real2.txt")
vim.cmd("normal a")
wait(function() return r71.state == "ready" end, "#71 ready after accepting the guess")
expect(r71.marks["real2.txt"].by == "you" and not r71.marks["real2.txt"].unsure, "accepted file is yours")
expect(view_of(r71):find("✎ 1 you", 1, true), "marks line counts the accepted file")
undo(r71)

-- 3. off-plan change outside the conflicts
r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2 }, outside = { ["outside.txt"] = "changed\n" }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "review" end, "#71 review for the outside file")
text = view_of(r71)
expect(text:find("? outside.txt", 1, true) and text:find("changed outside the conflicts", 1, true), "off-plan row\n" .. text)
goto_line("^  ? outside.txt")
vim.cmd("normal a")
wait(function() return r71.state == "ready" end, "#71 ready after accepting outside.txt")
expect(vim.tbl_contains(vim.split((git(wt71, "diff", "--name-only", r71.orig, "HEAD")), "\n"), "outside.txt"), "commit contains the outside file")
undo(r71)

-- 4. gave up, then fixed by hand
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "gave_up" end, "#71 gave up")
text = view_of(r71)
for _, expected in ipairs({ "agents", "gave up on 1", "real2.txt", "markers left", "◆ 2 kept" }) do
  expect(text:find(expected, 1, true), "lane shows " .. expected .. "\n" .. text)
end
expect(r71.state == "resolving" and merges.statusline() == "◆ #71 gave up", "statusline: " .. merges.statusline())
fix.push(r71, false)
expect(r71.state == "resolving", "nothing pushes while gave up")
merges.open_file(r71, vim.iter(r71.files):find(function(f) return f.path == "real2.txt" end))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x", "by hand", "z" })
vim.cmd("silent write")
wait(function() return r71.state == "ready" end, "#71 ready after hand edit")
expect(r71.marks["real2.txt"].by == "you", "hand-edited file is yours")
vim.cmd("bwipeout!")
undo(r71)

-- 5. time limit, then continue on the remaining file
r71 = resolving(71)
pr_ai.limit = 2
scenario({ run = { steps = { vim.tbl_extend("force", resolved_real, { sleep = 30 }) } } })
start_claude(r71)
wait(function() return phase(r71) == "paused" end, "#71 paused")
pr_ai.limit = 1200
expect(r71.ai.why:match("^hit .* limit$"), "paused reason: " .. tostring(r71.ai.why))
wait(function() return not alive(claude_pid()) end, "claude dead after the limit")
expect((git(wt71, "diff", "--cached", "--name-only")):find("real.txt", 1, true) and not (git(wt71, "ls-files", "-u")):find("real.txt", 1, true), "first file stays staged")
text = view_of(r71)
expect(text:find("progress kept · c continue 1", 1, true), "paused lane row\n" .. text)
scenario({ run = { steps = { resolved_real2 }, report = report({}) } })
vim.cmd("normal c")
wait(function() return r71.state == "ready" end, "#71 ready after continuing")
local last = calls()[#calls()]
expect(last.prompt:find("\nreal2.txt", 1, true) and not last.prompt:find("\nreal.txt", 1, true), "second run lists only the remaining file\n" .. last.prompt)
undo(r71)

-- 6. x stops the run and undoes it
r71 = resolving(71)
scenario({ run = { steps = { vim.tbl_extend("force", resolved_real, { sleep = 30 }) } } })
start_claude(r71)
wait(function() return phase(r71) == "running" and not (git(wt71, "ls-files", "-u")):find("real.txt", 1, true) end, "first file staged")
local pid = claude_pid()
vim.cmd("normal x")
wait(function() return r71.finished end, "#71 stopped and undone")
expect(not alive(pid), "claude process group killed")
tree_ok(wt71, r71.orig)
expect(r71.headline == "cancelled with x · back at " .. r71.orig:sub(1, 7) .. " exactly, Claude's 1 edits discarded", "headline: " .. tostring(r71.headline))
expect(vim.uv.fs_stat(r71.ai.log) ~= nil, "transcript kept")
local aborted = r71

-- 7. plan flow
local wt72 = tmp .. "/main-wt/plan"
pr_ai.plan_at = 3
local r72 = resolving(72)
local function snapshot() return (git(wt72, "ls-files", "-u")) .. "\n" .. (git(wt72, "diff")) end
local untouched = snapshot()
local plan_report = {
  summary = "formatting and a reapply", minutes = 6,
  groups = {
    { title = "only formatting differs", strategy = "take master, run prettier", kind = "format", files = { "fmt1.ts", "fmt2.ts" } },
    { title = "PR also changed code", strategy = "re-apply the PR's code", kind = "reapply", files = { "re.ts" }, keep = { { path = "re.ts", lines = { "const b = 20", "const c2 = 30" } } } },
    { title = "both changed logic", strategy = "Claude merges each one", kind = "merge", files = { "logic.ts" } },
  },
}
scenario({ plan = { report = plan_report } })
text = view_of(r72)
expect(text:find("Plans first", 1, true), "big fixes announce the plan")
vim.cmd("normal c")
wait(function() return r72.state == "plan" end, "#72 plan ready")
argv = calls()[#calls()].argv
expect(has(argv, "--json-schema"), "plan call has a json schema")
local allowed = vim.list_slice(argv, vim.fn.index(argv, "--allowedTools") + 2)
expect(not vim.iter(allowed):any(function(a) return a:find("Edit", 1, true) or a:find("Write", 1, true) end), "plan call allows no edit tools")
expect(argv[vim.fn.index(argv, "--tools") + 2] == "Read,Glob,Grep,Bash,Skill", "plan tools")
expect(snapshot() == untouched, "planning changed nothing")
expect(r72.ai.plan.groups[1].strategy == "take master's file; Neovim re-runs prettier with #72's config", "format strategy: " .. r72.ai.plan.groups[1].strategy)
expect(calls()[#calls()].prompt:find("Neovim re-runs prettier", 1, true) and calls()[#calls()].prompt:find("Don't run any formatter yourself.", 1, true), "plan prompt keeps Claude away from the formatter")
text = view_of(r72)
for _, expected in ipairs({ "plan ready", "only formatting differs", "PR also changed code", "both changed logic", "~6 min", "✓ plan" }) do
  expect(text:find(expected, 1, true), "plan view shows " .. expected .. "\n" .. text)
end
expect(merges.statusline() == "◆ #72 plan ready", "statusline: " .. merges.statusline())
local planned_calls = #calls()
vim.ui.input = function(opts, cb) cb("also keep the tab width") end
vim.cmd("normal s")
wait(function() return #calls() == planned_calls + 1 and r72.state == "plan" end, "#72 re-planned")
last = calls()[#calls()]
expect(last.prompt:find("also keep the tab width", 1, true) and last.prompt:find("Previous plan:", 1, true), "re-plan prompt carries the instruction")
vim.ui.input = function() error("vim.ui.input must be stubbed") end
local fmt1_ok = "function f() {\n  return 2\n}\n"
scenario({
  run = {
    steps = {
      { path = "fmt1.ts", content = fmt1_ok },
      { path = "fmt2.ts", content = "function g() {\n  return 2\n}\nextra()\n" },
      { path = "re.ts", content = "const a = 1\nconst b = 20\nconst c2 = 30\n" },
      { path = "logic.ts", content = "export const k = 1\nexport const m = 23\n" },
    },
    report = report({ { path = "logic.ts", result = "resolved", note = "kept both" } }),
  },
})
view_of(r72)
vim.cmd("normal y")
wait(function() return phase(r72) == "review" end, "#72 review")
last = calls()[#calls()]
expect(last.prompt:find("Group 1 · format · only formatting differs", 1, true) and last.prompt:find("keep in re.ts: const b = 20 | const c2 = 30", 1, true), "run prompt carries the plan")
local checks = r72.ai.checks
expect(checks.groups[1].ok == false and checks.groups[1].text == "1 of 2 differ from prettier on master", "format group: " .. vim.inspect(checks.groups[1]))
expect(r72.marks["fmt2.ts"].unsure.kind == "offplan" and r72.marks["fmt2.ts"].unsure.reason:find("planned formatting only; differs from prettier on master", 1, true), "off-plan reason")
expect(not r72.marks["fmt1.ts"].unsure, "correct formatting is not flagged")
expect(checks.groups[2].text:find("all 2 code lines present", 1, true), "reapply group: " .. vim.inspect(checks.groups[2]))
expect(checks.fmt and checks.fmt.text == "✓ prettier --check clean", "prettier check ran")
local prettier_calls = vim.tbl_map(vim.json.decode, vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG))
local checked = vim.tbl_filter(function(args) return not vim.tbl_contains(args, "--write") end, prettier_calls)
expect(vim.iter(prettier_calls):all(function(args) return args[1] == tmp .. "/main/node_modules/.bin/prettier" end), "only the main checkout's prettier runs")
expect(#checked > 0 and vim.iter(prettier_calls):all(function(args)
  local config = args[vim.fn.index(args, "--config") + 2]
  return config and vim.fs.basename(config) == ".prettierrc" and not vim.startswith(config, tmp .. "/main") and read(config) == '{ "useTabs": false }'
end), "nvim-side checks use the base branch's prettier config: " .. vim.inspect(checked))
text = view_of(r72)
for _, expected in ipairs({ "? fmt2.ts", "off-plan", "planned formatting only", "all 2 code lines present", "✓ prettier --check clean", "merged by Claude" }) do
  expect(text:find(expected, 1, true), "review view shows " .. expected .. "\n" .. text)
end
vim.cmd("normal ]q")
local qf = vim.tbl_map(function(entry) return vim.fs.basename(vim.api.nvim_buf_get_name(entry.bufnr)) end, vim.fn.getqflist())
expect(vim.deep_equal(qf, { "fmt2.ts", "logic.ts", "re.ts" }), "quickfix order: " .. vim.inspect(qf))
vim.cmd("cclose | silent! %bwipeout!")
undo(r72)

r72 = resolving(72)
untouched = snapshot()
scenario({ plan = { report = plan_report } })
start_claude(r72)
wait(function() return r72.state == "plan" end, "#72 plan ready again")
untouched = snapshot()
view_of(r72)
vim.cmd("normal x")
wait(function() return r72.state == "resolving" end, "#72 declined")
expect(r72.ai == nil and vim.uv.fs_stat(r72.gitdir .. "/MERGE_HEAD") ~= nil and snapshot() == untouched, "declining keeps the merge and changes nothing")
undo(r72)
pr_ai.plan_at = 50

-- 8. stopped at a plan step, then continued with the suggestion
r71 = resolving(71)
scenario({ run = { report = report({}, { status = "stopped", stopped = { group = 1, reason = "prettier changed 3 files", suggestion = "exclude vendor/" } }) } })
start_claude(r71)
wait(function() return phase(r71) == "stopped" end, "#71 stopped")
text = view_of(r71)
expect(text:find("plan step 1 stopped", 1, true) and text:find('claude "exclude vendor/" s applies that', 1, true), "stopped lane\n" .. text)
expect(merges.statusline() == "◆ #71 step 1 stopped", "statusline: " .. merges.statusline())
vim.ui.input = function(opts, cb) cb(opts.default) end
scenario({ run = { steps = { resolved_real, resolved_real2 }, report = report({}) } })
vim.cmd("normal s")
wait(function() return r71.state == "ready" end, "#71 ready after the continued run")
last = calls()[#calls()]
expect(last.prompt:find("Instructions from the user: exclude vendor/", 1, true), "continued run carries the suggestion")
vim.ui.input = function() error("vim.ui.input must be stubbed") end
undo(r71)

-- 9. queue: one agent at a time
pr_ai.max_agents = 1
local r73, r74 = resolving(73), resolving(74)
scenario({ run = { steps = { resolved_real }, sleep_end = 1.5, report = report({}) } })
local before_calls = #calls()
pr_ai.start(r73)
pr_ai.start(r74)
wait(function() return r73.ai and r74.ai and r74.ai.phase == "queued" end, "#74 queued")
expect(r73.ai.phase == "running" and r74.state == "claude", "first runs, second waits")
text = view_of(r74)
expect(text:find("queued, starts next", 1, true) and merges.statusline():find("+1 queued", 1, true), "queued row and statusline: " .. merges.statusline() .. "\n" .. text)
wait(function() return r73.state == "ready" end, "#73 ready")
wait(function() return r74.state == "ready" end, "#74 ready")
local started = vim.list_slice(calls(), before_calls + 1)
expect(#started == 2 and started[1].cwd == tmp .. "/main-wt/q1" and started[2].cwd == tmp .. "/main-wt/q2" and started[2].t - started[1].t >= 1.4, "start order and spacing")
pr_ai.max_agents = 2
undo(r73)
undo(r74)

-- 10. entry points
scenario({ run = { steps = { resolved_real }, report = report({}) } })
merges.open(merged)
vim.wait(150)
goto_line("^\\s\\+80\\s")
vim.cmd("normal c")
local r80
wait(function()
  r80 = fix.latest(main, 80, 0)
  return r80 and r80.state == "ready"
end, "#80 ready from c on a fallout row")
vim.cmd("normal q")
undo(r80)
local entry_calls = #calls()
r80 = pr_ai.start_pr(main, { number = 80, title = "PR 80", headRefName = "feat/entry", baseRefName = "master", _fix = "cmd" })
wait(function() return r80.state == "ready" and #calls() == entry_calls + 1 end, "start_pr reaches claude")
undo(r80)

-- 11. Neovim closed mid-run
r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2 }, sleep_end = 30, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "running" and (git(wt71, "ls-files", "-u")) == "" end, "both files staged")
pid = claude_pid()
vim.api.nvim_exec_autocmds("VimLeavePre", {})
wait(function() return not alive(pid) end, "claude dead after VimLeavePre")
local saved = vim.json.decode(read(r71.common .. "/pr-fix/71.json"))
expect(saved.ai.phase == "paused" and saved.ai.unchecked == true and saved.marks["easy.txt"].by == "easy", "state file records the pause: " .. vim.inspect(saved.ai))
vim.cmd("normal q")
review.merges = { merged }
fix.refresh(main)
local back
wait(function()
  back = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.number == 71 and r.state == "paused" and r.ai end)
  return back
end, "paused record restored")
expect(back.ai.phase == "paused" and back.ai.unchecked and #back.ai.files == 2, "restored ai state")
fix.resume(back)
wait(function() return back.state == "resolving" and not back.busy end, "restored record resumes")
vim.wait(300)
expect(back.state == "resolving" and vim.uv.fs_stat(back.gitdir .. "/MERGE_HEAD") ~= nil, "unchecked work keeps the merge open")
scenario({})
view_of(back)
vim.cmd("normal c")
wait(function() return back.state == "ready" end, "checks alone finish the restored run")
undo(back)

-- 12. transcript
table.insert(review.merges, 1, aborted)
text = view_of(aborted)
expect(text:find("t transcript for 24h", 1, true), "aborted row hints at the transcript\n" .. text)
vim.cmd("normal t")
local log_text = buffer()
expect(vim.api.nvim_buf_get_name(0) == aborted.ai.log, "transcript buffer: " .. vim.api.nvim_buf_get_name(0))
expect(log_text:find("▸ Edit " .. wt71 .. "/real.txt", 1, true) and log_text:find("real.txt: merging real", 1, true), "transcript content\n" .. log_text)
vim.cmd("close")

-- 14. escape routes in the argv
for _, arg in ipairs({
  "Edit(/" .. r70.gitdir .. "/**)", "Write(/" .. r70.gitdir .. "/**)", "Edit(/" .. r70.common .. "/**)", "Write(/" .. wt70 .. "/.git/**)",
  "Bash(git diff --output:*)", "Bash(git log --output:*)", "Bash(git * --output*)", "Bash(git diff --no-index:*)",
  "Edit(/" .. wt70 .. "/node_modules/**)", "Write(/" .. wt70 .. "/node_modules/**)", "Edit(/" .. wt70 .. "/**/.prettierrc*)",
  "Write(/" .. wt70 .. "/**/prettier.config.*)", "Edit(/" .. wt70 .. "/.git)", "Write(/" .. wt70 .. "/.git)",
  "Edit(/" .. wt70 .. "/.GIT)", "Write(/" .. wt70 .. "/.gIt)", "Edit(/" .. wt70 .. "/.Git/**)", "Write(/" .. wt70 .. "/.giT/**)",
}) do
  expect(has(calls()[1].argv, arg), "argv denies " .. arg)
end
expect(not has(calls()[1].argv, "Bash(git merge-file:*)"), "git merge-file is not allowed")
for _, entry in ipairs(calls()) do
  expect(not vim.iter(entry.argv):any(function(arg) return arg:find("prettier", 1, true) and not arg:find("prettierrc", 1, true) and not arg:find("prettier.config", 1, true) and not arg:find("prettierignore", 1, true) end), "Claude gets no formatter permission: " .. vim.inspect(entry.argv))
end
local denied_at = vim.fn.index(calls()[1].argv, "--disallowedTools")
expect(vim.fn.index(calls()[1].argv, "Edit(/" .. r70.common .. "/**)") > denied_at and vim.fn.index(calls()[1].argv, "--tools") > denied_at, "git dir denies sit among the disallowed tools")

-- 15. a hand fix is staged, so the commit keeps the user's version
r71 = resolving(71)
scenario({
  run = {
    steps = { resolved_real, resolved_real2 },
    report = report({ { path = "real2.txt", result = "unsure", note = "not sure", guess = "g", line = 2 } }),
  },
})
start_claude(r71)
wait(function() return phase(r71) == "review" end, "#71 review for the hand fix")
merges.open_file(r71, { path = "real2.txt", kind = "content" })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x", "my own version", "z" })
vim.cmd("silent write")
wait(function() return r71.state == "ready" end, "#71 ready after the hand fix")
expect((git(wt71, "show", "HEAD:real2.txt")) == "x\nmy own version\nz", "the merge commit keeps the hand fix")
vim.cmd("bwipeout!")
undo(r71)

-- 16. the index never commits conflict markers
local wt73 = tmp .. "/main-wt/q1"
local r73b = resolving(73)
vim.fn.writefile({ "a", "<<<<<<< HEAD", "mine", "=======", "theirs", ">>>>>>> master", "c" }, wt73 .. "/real.txt")
git(wt73, "add", "real.txt")
fix.rescan(r73b)
wait(function() return phase(r73b) == nil and r73b.files[1].status == "real" and not r73b.busy end, "#73 blocked by staged markers")
expect(r73b.state == "resolving" and (git(wt73, "rev-parse", "HEAD")) == r73b.orig, "nothing was committed")
vim.fn.writefile({ "a", "fixed", "c" }, wt73 .. "/real.txt")
fix.rescan(r73b)
wait(function() return r73b.state == "ready" end, "#73 ready once the file is clean")
expect((git(wt73, "show", "HEAD:real.txt")) == "a\nfixed\nc", "the clean file was staged and committed")
undo(r73b)

-- 17. changes to conflict files that weren't handed are off-plan
r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2, { path = "easy.txt", content = "1\nclaude\ntheirs3\n4\n5\n6\n" } }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "review" end, "#71 review for the easy file")
expect(r71.marks["easy.txt"].unsure and r71.marks["easy.txt"].unsure.reason == "changed outside the conflicts", "an accepted easy file Claude rewrote is flagged")
expect(vim.tbl_contains(pr_ai.unsure_paths(r71), "easy.txt"), "easy.txt is unsure")
undo(r71)

-- 18. pathspecs are literal
r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2 }, outside = { ["g[1].txt"] = "changed\n" }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "review" end, "#71 review for the glob file")
vim.fn.writefile({ "my edit" }, wt71 .. "/g1.txt")
text = view_of(r71)
goto_line("^  ? g\\[1\\].txt")
vim.cmd("normal a")
wait(function() return r71.state == "ready" end, "#71 ready after accepting g[1].txt")
local committed = vim.split((git(wt71, "diff", "--name-only", r71.orig, "HEAD")), "\n")
expect(vim.tbl_contains(committed, "g[1].txt") and not vim.tbl_contains(committed, "g1.txt"), "only the literal path was staged: " .. vim.inspect(committed))
git(wt71, "checkout", "--", "g1.txt")
undo(r71)

-- 19. a failed record stays failed after a restart
r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2 }, commit = true, sleep_end = 0, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "failed" end, "#71 failed after claude committed")
local claude_head = (git(wt71, "rev-parse", "HEAD"))
vim.api.nvim_exec_autocmds("VimLeavePre", {})
saved = vim.json.decode(read(r71.common .. "/pr-fix/71.json"))
expect(saved.ai.phase == "failed", "VimLeavePre leaves failed alone: " .. tostring(saved.ai.phase))
review.merges = { merged }
fix.refresh(main)
wait(function()
  back = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.number == 71 and phase(r) == "failed" end)
  return back
end, "failed record restored")
fix.resume(back)
vim.wait(500)
expect(back.state == "claude" and back.ai.phase == "failed", "resume never finalizes a failed record: " .. back.state)
expect(merges.statusline() == "◆ #71 failed", "statusline: " .. merges.statusline())
undo(back)
expect((git(wt71, "rev-parse", "HEAD")) == back.orig and claude_head ~= back.orig, "x goes back to the original commit")

-- 20. closing Neovim empties the queue
pr_ai.max_agents = 1
r73, r74 = resolving(73), resolving(74)
scenario({ run = { steps = { resolved_real }, sleep_end = 2, report = report({}) } })
before_calls = #calls()
pr_ai.start(r73)
pr_ai.start(r74)
wait(function() return r73.ai and r74.ai and r74.ai.phase == "queued" end, "#74 queued again")
wait(function() return #calls() == before_calls + 1 end, "#73 claude started")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
wait(function() return not r73.ai.proc end, "#73 process gone")
vim.wait(800)
expect(#calls() == before_calls + 1 and r74.ai.phase == "paused" and not r74.ai.proc, "the queued fix never starts after VimLeavePre: " .. (#calls() - before_calls) .. " " .. tostring(r74.ai.phase))
pr_ai.max_agents = 2
fix.abort(r73)
fix.abort(r74)
wait(function() return r73.finished and r74.finished end, "#73 and #74 undone")

-- 21. a restored plan needs y again, and outside changes made before closing are still flagged
r72 = resolving(72)
pr_ai.plan_at = 3
scenario({ plan = { report = plan_report } })
start_claude(r72)
wait(function() return r72.state == "plan" end, "#72 plan ready for the restart")
review.merges = { merged }
fix.refresh(main)
wait(function()
  back = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.number == 72 and r.state == "paused" end)
  return back
end, "plan record restored")
expect(pr_ai.label(back) == "plan ready", "restored plan label: " .. tostring(pr_ai.label(back)))
fix.resume(back)
wait(function() return back.state == "plan" end, "restored record shows the plan again")
local before = #calls()
view_of(back)
vim.cmd("normal c")
vim.wait(300)
expect(#calls() == before and back.state == "plan", "c does not run the restored plan")
undo(back)
pr_ai.plan_at = 50

r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2 }, outside = { ["outside.txt"] = "changed\n" }, sleep_end = 30, report = report({}) } })
start_claude(r71)
wait(function() return read(wt71 .. "/outside.txt") == "changed" end, "claude changed the outside file")
pid = claude_pid()
vim.api.nvim_exec_autocmds("VimLeavePre", {})
wait(function() return not alive(pid) end, "claude dead before the restart")
review.merges = { merged }
fix.refresh(main)
wait(function()
  back = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.number == 71 and r.state == "paused" and r.ai end)
  return back
end, "unchecked record restored")
expect(back.ai.snap ~= nil, "the snapshot survived the restart")
fix.resume(back)
wait(function() return back.state == "resolving" and not back.busy end, "restored unchecked record resumes")
view_of(back)
vim.cmd("normal c")
wait(function() return phase(back) == "review" end, "restored checks finish")
expect(back.marks["outside.txt"] and back.marks["outside.txt"].unsure, "outside change made before closing is flagged")
vim.cmd("normal q")
git(wt71, "checkout", "--", "outside.txt")
undo(back)

-- 22. undo verifies the result and handles a stale index.lock
r71 = resolving(71)
scenario({ run = { steps = { vim.tbl_extend("force", resolved_real, { sleep = 30 }) } } })
start_claude(r71)
wait(function() return phase(r71) == "running" and not (git(wt71, "ls-files", "-u")):find("real.txt", 1, true) end, "first file staged for the lock test")
local lock = r71.gitdir .. "/index.lock"
vim.fn.writefile({}, lock)
vim.cmd("normal x")
wait(function() return r71.finished end, "#71 undone despite a stale lock")
expect(not vim.uv.fs_stat(lock), "stale lock removed")
tree_ok(wt71, r71.orig)
expect(r71.headline:find("back at " .. r71.orig:sub(1, 7) .. " exactly", 1, true), "headline after the lock retry: " .. tostring(r71.headline))

r71 = resolving(71)
start_claude(r71)
wait(function() return phase(r71) == "running" and not (git(wt71, "ls-files", "-u")):find("real.txt", 1, true) end, "first file staged for the held lock test")
lock = r71.gitdir .. "/index.lock"
local holder = vim.system({ "sh", "-c", "exec sleep 30 > '" .. lock .. "'" })
wait(function() return vim.uv.fs_stat(lock) ~= nil end, "lock held")
vim.wait(200)
vim.cmd("normal x")
wait(function() return r71.detail and r71.detail:find("could not go back", 1, true) end, "undo reports a held lock")
expect(not r71.finished and vim.uv.fs_stat(lock) ~= nil, "a lock another process holds is left alone")
holder:kill(15)
holder:wait()
os.remove(lock)
vim.wait(100)
fix.abort(r71)
wait(function() return r71.finished end, "#71 undone once the lock is gone")
tree_ok(wt71, r71.orig)

-- 23. marks the user set during a run survive the checks
r71 = resolving(71)
scenario({ run = { steps = { vim.tbl_extend("force", resolved_real, { sleep = 1 }), resolved_real2 }, report = report({ { path = "real.txt", result = "unsure", note = "n", guess = "g" } }) } })
start_claude(r71)
wait(function() return phase(r71) == "running" and r71.marks end, "#71 running for the mark test")
r71.marks["real.txt"] = { by = "you" }
r71.marks["outside.txt"] = { by = "you", at = r71.ai.spawned + 0.001 }
vim.fn.writefile({ "mine" }, wt71 .. "/outside.txt")
git(wt71, "add", "outside.txt")
wait(function() return r71.state == "ready" end, "#71 ready with a hand-owned mark")
expect(r71.marks["real.txt"].by == "you" and not r71.marks["real.txt"].unsure, "check keeps the user's mark")
expect(not r71.marks["outside.txt"].unsure, "a file the user saved during the run is not flagged off-plan")
undo(r71)

-- 24. an orphaned merge is adopted, never refused
local function orphan_merge(resolve)
  git(wt71, "merge", "--no-ff", "--no-edit", "origin/master")
  if not resolve then return end
  vim.fn.writefile({ "1", "mine2", "theirs3", "4", "5", "6" }, wt71 .. "/easy.txt")
  vim.fn.writefile({ "a", "by hand", "c" }, wt71 .. "/real.txt")
  vim.fn.writefile({ "x", "by hand", "z" }, wt71 .. "/real2.txt")
end
local orig71 = (git(wt71, "rev-parse", "HEAD"))
orphan_merge(true)
git(wt71, "add", "-A")
local adopted = fix.start(merged, items[71])
wait(function() return adopted.awaiting_p and not adopted.busy end, "adopted merge waits for p")
expect(adopted.note == "found a merge in progress (not started here)" and adopted.orig == orig71, "adopted record: " .. tostring(adopted.note))
expect(adopted.state == "resolving" and adopted.detail == "adopted · p commits and pushes after you review", "adopted detail: " .. tostring(adopted.detail))
expect((git(wt71, "rev-parse", "HEAD")) == orig71 and vim.uv.fs_stat(adopted.gitdir .. "/MERGE_HEAD") ~= nil, "nothing committed without p")
undo(adopted)

orphan_merge()
adopted = fix.start(merged, items[71])
wait(function() return adopted.state == "resolving" and #adopted.files > 0 and not adopted.busy end, "adopted merge with open conflicts")
expect(adopted.adopted == "merge" and adopted.orig == orig71, "adopted merge keeps HEAD as the way back")
undo(adopted)

git(wt71, "rebase", "origin/master")
expect(vim.uv.fs_stat(git(wt71, "rev-parse", "--absolute-git-dir") .. "/rebase-merge") ~= nil, "a rebase is in progress")
local adopted_rebase = fix.start(merged, items[71])
wait(function() return adopted_rebase.state == "resolving" and adopted_rebase.adopted == "rebase" end, "adopted rebase")
vim.wait(300)
expect(adopted_rebase.state == "resolving" and adopted_rebase.orig == orig71, "adopted rebase never finishes by itself, orig is the old tip")
undo(adopted_rebase)

-- 25. starting a fix replaces earlier finished failed or aborted records of the same PR
local function fixes_of(number)
  return #vim.tbl_filter(function(r) return r.kind == "fix" and r.number == number end, review.merges)
end
for _ = 1, 2 do
  local failed_fix = fix.start(merged, vim.tbl_extend("force", items[71], { base = "nope" }))
  wait(function() return failed_fix.finished end, "#71 fails")
end
local again_a = fix.start(merged, items[71])
wait(function() return again_a.state == "resolving" and not again_a.busy end, "#71 resolving after failures")
expect(fixes_of(71) == 1, "earlier failed records are dropped: " .. fixes_of(71))
undo(again_a)
local again_b = fix.start(merged, items[71])
wait(function() return again_b.state == "resolving" and not again_b.busy end, "#71 resolving after an abort")
expect(fixes_of(71) == 1 and not vim.tbl_contains(review.merges, again_a), "the aborted record is replaced")
undo(again_b)

-- 26. alt-c on an orphaned merge adopts it once, keeps the user's staged work and starts Claude
local function start_71() return pr_ai.start_pr(main, { number = 71, title = "PR 71", headRefName = "feat/a", baseRefName = "master", _fix = "cmd" }) end
orphan_merge()
vim.fn.writefile({ "a", "by hand", "c" }, wt71 .. "/real.txt")
git(wt71, "add", "real.txt")
scenario({ run = { steps = { resolved_real2 }, report = report({}) } })
before_calls = #calls()
local via_picker = start_71()
wait(function() return via_picker.awaiting_p and not via_picker.busy end, "alt-c adopted merge resolved by Claude")
last = calls()[#calls()]
expect(#calls() == before_calls + 1 and last.prompt:find("\nreal2.txt", 1, true) and not last.prompt:find("\nreal.txt", 1, true), "Claude got only the open file")
local paths = vim.tbl_map(function(f) return f.path end, via_picker.files)
expect(#paths == #vim.fn.uniq(vim.fn.sort(vim.deepcopy(paths))), "files are not duplicated: " .. vim.inspect(paths))
expect((git(wt71, "show", ":real.txt")) == "a\nby hand\nc" and vim.uv.fs_stat(via_picker.gitdir .. "/MERGE_HEAD") ~= nil, "the staged hand resolution survives")
expect((git(wt71, "rev-parse", "HEAD")) == orig71, "nothing committed before p")
undo(via_picker)

-- 27. merges that aren't of the base, or carry staged changes outside the merge, are refused untouched
git(wt71, "merge", "--no-commit", "--no-ff", "origin/feat/plan")
local foreign = fix.start(merged, items[71])
wait(function() return foreign.finished end, "a foreign merge is refused")
expect(foreign.state == "failed" and foreign.reason == "merge of origin/feat/plan in progress, not master · finish it by hand or git merge --abort", "refusal: " .. tostring(foreign.reason))
expect(vim.uv.fs_stat(foreign.gitdir .. "/MERGE_HEAD") ~= nil, "the foreign merge is left alone")
git(wt71, "merge", "--abort")
orphan_merge()
vim.fn.writefile({ "sneaky" }, wt71 .. "/outside.txt")
git(wt71, "add", "outside.txt")
local staged_outside = fix.start(merged, items[71])
wait(function() return staged_outside.finished end, "staged outside changes are refused")
expect(staged_outside.reason == "staged changes outside the merge: outside.txt · finish it by hand or git merge --abort", "refusal: " .. tostring(staged_outside.reason))
expect((git(wt71, "show", ":outside.txt")) == "sneaky", "the staged change is left alone")
git(wt71, "merge", "--abort")
git(wt71, "checkout", "--", "outside.txt")
expect((git(wt71, "status", "--porcelain")) == "", "clean after the refusals")

-- 28. alt-c before opening the merges window picks up the saved failed record
r71 = resolving(71)
scenario({ run = { steps = { resolved_real, resolved_real2 }, commit = true, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "failed" end, "#71 failed for the picker test")
vim.cmd("normal q")
review.merges = { merged }
before_calls = #calls()
local picked = start_71()
wait(function() return phase(picked) == "failed" and picked.state == "claude" and not picked.busy end, "alt-c shows the saved failed record")
vim.wait(300)
expect(picked.orig == r71.orig and #calls() == before_calls, "orig comes from the state file and Claude doesn't start")
expect(vim.json.decode(read(r71.common .. "/pr-fix/71.json")).orig == r71.orig, "the state file is not overwritten")
undo(picked)

-- 29. x removes what Claude changed outside the merge
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, outside = { ["outside.txt"] = "claude\n", ["made.txt"] = "new\n" }, sleep_end = 30, report = report({}) } })
start_claude(r71)
wait(function() return vim.uv.fs_stat(wt71 .. "/made.txt") ~= nil end, "claude made a file")
vim.cmd("normal x")
wait(function() return r71.finished end, "#71 undone with Claude's extra files")
tree_ok(wt71, r71.orig)
expect(not vim.uv.fs_stat(wt71 .. "/made.txt") and read(wt71 .. "/outside.txt") == "o", "Claude's outside edits are gone")
expect(r71.headline:find("exactly", 1, true), "headline: " .. tostring(r71.headline))

-- 30. a gave-up file fixed in a terminal releases the hold
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "gave_up" and not r71.busy end, "#71 gave up for the terminal fix")
expect(pr_ai.label(r71) == "gave up", "label while held: " .. tostring(pr_ai.label(r71)))
vim.fn.writefile({ "x", "terminal", "z" }, wt71 .. "/real2.txt")
git(wt71, "add", "real2.txt")
fix.rescan(r71)
wait(function() return r71.state == "ready" end, "#71 ready after a terminal fix")
expect(r71.marks["real2.txt"].by == "you" and not r71.marks["real2.txt"].gave_up, "the terminal fix is yours")
expect((git(wt71, "show", "HEAD:real2.txt")) == "x\nterminal\nz", "the commit has the terminal fix")
undo(r71)

-- 31. a continuation run that rewrites a file you fixed is off-plan
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "gave_up" and not r71.busy end, "#71 gave up before the continuation")
merges.open_file(r71, { path = "real.txt", kind = "content" })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "mine by hand", "c" })
vim.cmd("silent write")
vim.cmd("bwipeout!")
wait(function() return not r71.busy and r71.state == "resolving" end, "#71 rescanned after the hand fix")
expect(r71.marks["real.txt"].by == "you" and (git(wt71, "show", ":real.txt")) == "a\nmine by hand\nc", "hand fix staged")
scenario({ run = { steps = { resolved_real2, { path = "real.txt", content = "a\nclaude again\nc\n" } }, report = report({}) } })
pr_ai.start(r71)
wait(function() return phase(r71) == "review" end, "continuation flags the overwrite")
expect(r71.marks["real.txt"].unsure and r71.marks["real.txt"].unsure.reason == "changed outside the conflicts", "rewritten hand fix is off-plan: " .. vim.inspect(r71.marks["real.txt"]))
undo(r71)

-- 32. the merges float survives :edit inside it
merges.open()
vim.wait(100)
vim.cmd("edit " .. vim.fn.fnameescape(wt71 .. "/outside.txt"))
review.core.changed()
vim.wait(200)
merges.open()
vim.wait(100)
expect(vim.api.nvim_win_get_config(0).relative ~= "" and vim.bo.buftype == "nofile", "merges reopens as a float")
vim.cmd("normal q")
vim.cmd("silent! %bwipeout!")

-- 34. x works when Claude left an unstaged edit on a file the merge brought in
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, outside = { ["fmt1.ts"] = "claude\n" }, sleep_end = 30, report = report({}) } })
start_claude(r71)
wait(function() return read(wt71 .. "/fmt1.ts") == "claude" end, "claude edited a merged file without staging it")
vim.cmd("normal x")
wait(function() return r71.finished end, function() return "#71 undone despite the unstaged edit (" .. tostring(r71.detail) .. ")" end)
tree_ok(wt71, r71.orig)
expect(read(wt71 .. "/fmt1.ts") == "function f() {\n  return 1\n}", "the merged file is back")

-- 34b. x works when Claude formats a conflict file after staging it
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, outside = { ["real.txt"] = "a\nformatted\nc\n" }, sleep_end = 30, report = report({}) } })
start_claude(r71)
wait(function() return read(wt71 .. "/real.txt") == "a\nformatted\nc" end, "claude edited a staged conflict file")
expect((git(wt71, "status", "--porcelain", "--", "real.txt")) == "MM real.txt", "staged and edited again")
vim.cmd("normal x")
wait(function() return r71.finished end, "#71 undone after the staged-then-edited conflict file")
tree_ok(wt71, r71.orig)

-- 34c. Neovim formats what Claude resolved, with the base config, and stages it
r71 = resolving(71)
local writes_before = #vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG)
scenario({ run = { steps = { { path = "real.txt", content = "a\n\tresolved  \nc\n" }, resolved_real2 }, report = report({}) } })
start_claude(r71)
wait(function() return r71.state == "ready" end, "#71 ready after nvim formatted")
expect((git(wt71, "show", "HEAD:real.txt")) == "a\n  resolved\nc", "the commit has the formatted file: " .. (git(wt71, "show", "HEAD:real.txt")))
local writes = vim.tbl_filter(function(args) return vim.tbl_contains(args, "--write") end, vim.tbl_map(vim.json.decode, vim.list_slice(vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG), writes_before + 1)))
expect(#writes == 1 and vim.tbl_contains(writes[1], "real.txt") and vim.tbl_contains(writes[1], "real2.txt") and vim.tbl_contains(writes[1], "--config"), "one formatting call with the base config: " .. vim.inspect(writes))
undo(r71)

-- 35. a restored plan never runs without y, even through alt-c
pr_ai.plan_at = 3
r72 = resolving(72)
scenario({ plan = { report = plan_report } })
start_claude(r72)
wait(function() return r72.state == "plan" end, "#72 plan ready before alt-c")
vim.cmd("normal q")
review.merges = { merged }
before_calls = #calls()
local planned_pick = pr_ai.start_pr(main, { number = 72, title = "PR 72", headRefName = "feat/plan", baseRefName = "master", _fix = "cmd" })
wait(function() return planned_pick.state == "paused" and planned_pick.ai and not planned_pick.busy end, "alt-c restores the plan record")
expect(not planned_pick.ai_wanted, "a revived plan record doesn't auto-start")
fix.resume(planned_pick)
wait(function() return planned_pick.state == "plan" and not planned_pick.busy and not planned_pick.scanning and #planned_pick.files > 0 end, "the restored plan waits for y")
planned_pick.state = "resolving"
expect(pr_ai.start(planned_pick), "c reaches the plan check")
wait(function() return planned_pick.state == "plan" and not planned_pick.busy end, "c on a restored plan shows the plan again")
vim.wait(300)
expect(#calls() == before_calls, "the restored plan didn't run: " .. (#calls() - before_calls))
undo(planned_pick)
pr_ai.plan_at = 50

-- 36. a file prettier can't parse is held, never committed
r71 = resolving(71)
scenario({ run = { steps = { { path = "real.txt", content = "a\nSYNTAX ERROR\nc\n" }, { path = "real2.txt", content = "x\n\tfine\nz\n" } }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "review" and not r71.busy end, "#71 held after a prettier parse error")
expect(r71.marks["real.txt"].unsure and r71.marks["real.txt"].unsure.reason == "prettier couldn't parse: [error] real.txt: SyntaxError: bad input (1:1)", "parse error mark: " .. vim.inspect(r71.marks["real.txt"]))
expect(not r71.marks["real2.txt"].unsure and r71.state == "resolving" and (git(wt71, "rev-parse", "HEAD")) == r71.orig, "the other file is fine and nothing is committed")
undo(r71)

-- 37. a prettier crash holds every file it was given
r71 = resolving(71)
scenario({ run = { steps = { { path = "real.txt", content = "a\nCRASH\nc\n" }, resolved_real2 }, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "review" and not r71.busy end, "#71 held after a prettier crash")
for _, path in ipairs({ "real.txt", "real2.txt" }) do
  expect(r71.marks[path].unsure and r71.marks[path].unsure.reason == "prettier failed: boom", path .. " crash mark: " .. vim.inspect(r71.marks[path]))
end
expect(r71.state == "resolving" and (git(wt71, "rev-parse", "HEAD")) == r71.orig, "nothing is committed after a crash")
undo(r71)

-- 38. a run that plants another .git: no git runs against it, and .git is put back
local fsmonitor_ran = tmp .. "/fsmonitor-ran"
local evil_line = "gitdir: " .. tmp .. "/evil/.git"
local dotgit = read(wt71 .. "/.git")
expect(dotgit ~= evil_line, "the worktree has its own .git")
r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, outside = { [".git"] = evil_line .. "\n" }, sleep_end = 30, report = report({}) } })
start_claude(r71)
pid = nil
wait(function()
  pid = pid or claude_pid()
  return phase(r71) == "failed"
end, "#71 failed after .git changed")
expect(r71.ai.why == "worktree .git was changed and has been restored", "why: " .. tostring(r71.ai.why))
expect(read(wt71 .. "/.git") == dotgit, "the known .git is written back")
wait(function() return not alive(pid) end, "claude stopped after .git changed")
expect(not vim.uv.fs_stat(fsmonitor_ran), "the planted fsmonitor never ran")
undo(r71)

r71 = resolving(71)
start_claude(r71)
wait(function() return read(wt71 .. "/.git") == evil_line end, "claude planted .git again")
vim.cmd("normal x")
wait(function() return r71.finished end, function() return "#71 undone right after the hijack (" .. tostring(r71.detail) .. ")" end)
expect(not vim.uv.fs_stat(fsmonitor_ran) and read(wt71 .. "/.git") == dotgit, "x after a hijack never runs the planted fsmonitor")
tree_ok(wt71, r71.orig)

r71 = resolving(71)
scenario({ run = { steps = { resolved_real }, sleep_end = 30, report = report({}) } })
start_claude(r71)
wait(function() return phase(r71) == "running" and not (git(wt71, "ls-files", "-u")):find("real.txt", 1, true) end, "first file staged before the restart")
pid = claude_pid()
vim.api.nvim_exec_autocmds("VimLeavePre", {})
wait(function() return not alive(pid) end, "claude dead before the hijacked restart")
vim.cmd("normal q")
expect(vim.json.decode(read(r71.common .. "/pr-fix/71.json")).gitdir == r71.gitdir, "the state file knows the worktree's git dir")
vim.fn.writefile({ evil_line }, wt71 .. "/.git")
review.merges = { merged }
fix.refresh(main)
wait(function()
  back = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.number == 71 and r.state == "paused" end)
  return back
end, "hijacked record restored")
vim.wait(300)
expect(back.detail == "worktree .git was changed and has been restored · check it before going on" and #back.files == 0, "restore warns and doesn't scan: " .. tostring(back.detail))
expect(read(wt71 .. "/.git") == dotgit and not vim.uv.fs_stat(fsmonitor_ran), "restore repaired .git without running the planted fsmonitor")
fix.resume(back)
wait(function() return back.state == "resolving" and not back.busy and #back.files > 0 end, "resume scans the repaired worktree")
undo(back)

-- 33. an adopted merge commits and pushes only on p, and a failed commit never aborts it
orphan_merge(true)
git(wt71, "add", "-A")
adopted = fix.start(merged, items[71])
wait(function() return adopted.awaiting_p and not adopted.busy end, "adopted merge waits for p again")
local executable = vim.fn.executable
vim.fn.executable = function(name) return name ~= "delta" and executable(name) or 0 end
view_of(adopted)
vim.cmd("normal d")
vim.fn.executable = executable
expect(buffer():find("+by hand", 1, true) and buffer():find("+mine2", 1, true) == nil, "d previews the adopted merge against your branch\n" .. buffer())
vim.cmd("close")
vim.cmd("normal q")
local lock71 = adopted.gitdir .. "/index.lock"
vim.fn.writefile({}, lock71)
fix.push(adopted, false)
wait(function() return adopted.detail and adopted.detail:find("commit failed", 1, true) and not adopted.busy end, "commit failure is reported")
expect(adopted.state == "resolving" and vim.uv.fs_stat(adopted.gitdir .. "/MERGE_HEAD") ~= nil and (git(wt71, "show", ":real.txt")) == "a\nby hand\nc", "the adopted merge is kept")
os.remove(lock71)
expect(adopted.awaiting_p, "p still works after a failed commit")
fix.push(adopted, false)
wait(function() return adopted.state == "fixed" end, "p commits and pushes the adopted merge")
expect(remote_sha("feat/a") == (git(wt71, "rev-parse", "HEAD")) and (git(wt71, "rev-list", "--parents", "-n1", "HEAD")):find(orig71, 1, true), "the adopted merge was pushed")

-- 39. a base config in package.json is used without its plugins
git(main, "rm", "-q", ".prettierrc")
vim.fn.writefile({ vim.json.encode({ name = "x", prettier = { useTabs = false, plugins = { "./evil.cjs" } } }) }, main .. "/package.json")
git(main, "add", "package.json")
git(main, "commit", "-qm", "prettier config in package.json")
git(main, "push", "-q", "origin", "master")
local tabbed = { path = "real.txt", content = "a\n\tresolved\nc\n" }
local wt74 = tmp .. "/main-wt/q2"
local r73c = resolving(73)
local logged = #vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG)
scenario({ run = { steps = { tabbed }, report = report({}) } })
pr_ai.start(r73c)
wait(function() return r73c.state == "ready" end, "#73 ready with the package.json config")
expect((git(wt73, "show", "HEAD:real.txt")) == "a\n  resolved\nc", "formatted with the package.json config")
local write_call = vim.iter(vim.tbl_map(vim.json.decode, vim.list_slice(vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG), logged + 1))):find(function(args) return vim.tbl_contains(args, "--write") end)
local pkg_config = write_call and write_call[vim.fn.index(write_call, "--config") + 2]
expect(pkg_config and vim.fs.basename(pkg_config) == ".prettierrc.json" and vim.deep_equal(vim.json.decode(read(pkg_config)), { useTabs = false }), "the package.json prettier key without plugins: " .. vim.inspect(write_call))
undo(r73c)

-- 40. without a base config Neovim neither formats nor claims the format check
git(main, "rm", "-q", "package.json")
git(main, "commit", "-qm", "no prettier config")
git(main, "push", "-q", "origin", "master")
local r74c = resolving(74)
logged = #vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG)
scenario({ run = { steps = { tabbed }, report = report({}) } })
pr_ai.start(r74c)
wait(function() return r74c.state == "ready" end, "#74 ready without a config")
expect((git(wt74, "show", "HEAD:real.txt")) == "a\n\tresolved\nc" and #vim.fn.readfile(vim.env.FAKE_PRETTIER_LOG) == logged, "nothing was formatted")
undo(r74c)
pr_ai.plan_at = 3
r72 = resolving(72)
scenario({
  plan = { report = plan_report },
  run = { steps = { { path = "fmt1.ts", content = fmt1_ok }, { path = "fmt2.ts", content = "function g() {\n  return 2\n}\n" }, { path = "re.ts", content = "const a = 1\nconst b = 20\nconst c2 = 30\n" }, { path = "logic.ts", content = "export const k = 1\nexport const m = 23\n" } }, report = report({}) },
})
start_claude(r72)
wait(function() return r72.state == "plan" end, "#72 plan without a config")
last = calls()[#calls()]
expect(not last.prompt:find('- "format"', 1, true) and last.prompt:find("no usable prettier config on master", 1, true), "the plan prompt offers no format kind")
expect(r72.ai.plan.groups[1].kind == "merge" and r72.ai.plan.groups[1].strategy == "Claude merges each one (no prettier config on master)", "format groups fold into merge: " .. vim.inspect(r72.ai.plan.groups[1]))
pr_ai.run(r72)
wait(function() return r72.state == "ready" or phase(r72) == "review" end, "#72 checked without a config")
vim.cmd("normal q")
undo(r72)
pr_ai.plan_at = 50

local stray = vim.tbl_filter(function(note) return not note:match("^Copied:") end, notes)
expect(#stray == 0, "no stray notifications: " .. table.concat(stray, " | "))

print("ok")
vim.cmd("qa!")
LUA

PATH="$tmp/bin:$PATH" nvim --headless "+cd $tmp/main" "+luafile $tmp/test.lua" +cquit 2>&1
