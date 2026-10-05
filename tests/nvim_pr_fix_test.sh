#!/usr/bin/env bash
# Conflict fix of nvim/lua/config/pr_fix.lua and the merges dashboard: the pure
# resolver, the in-memory probe, the merge and stacked-rebase runners (real temp
# git repos with a bare remote), guards, abort, recovery and the dashboard, with a
# fake `gh`. Nothing touches a real remote.
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
local fix = require("config.pr_fix")

local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\n")
    vim.cmd("cquit 1")
  end
end

local function lines(...) return table.concat({ ... }, "\n") .. "\n" end

local base = lines("{", "format:check", "wt:sweep", "preview", "test", "}")
local res = fix.resolve(base, lines("{", "format:check", "wt:sweep", "pr:brief", "preview", "test", "}"),
  lines("{", "format:check", "preview", "test", "}"))
expect(res.hard == 0, "case 1 is easy")
expect(res.result == lines("{", "format:check", "pr:brief", "preview", "test", "}"), "case 1 result: " .. res.result)
expect(#res.clusters == 1 and res.clusters[1].before == "format:check" and res.clusters[1].after == "preview", "case 1 cluster and context")

res = fix.resolve(lines("a", "b", "c", "d"), lines("a", "B", "c", "d"), lines("a", "b", "C", "d"))
expect(res.hard == 0 and res.result == lines("a", "B", "C", "d"), "case 2 adjacent edits merge")

res = fix.resolve(lines("x"), lines("y"), lines("z"))
expect(res.hard == 1 and res.clusters[1].hard and res.clusters[1].pr_line == 1, "case 3 same line is hard")
expect(res.result:find("<<<<<<<", 1, true) and res.result:find(">>>>>>>", 1, true), "case 3 markers")

res = fix.resolve(lines("a", "b"), lines("a", "one", "b"), lines("a", "two", "b"))
expect(res.hard == 1, "case 4 different inserts at one gap are hard")

res = fix.resolve(lines("a", "b", "c", "d", "e", "f"), lines("a", "B", "c", "D", "e", "f"), lines("a", "B", "c", "d", "E", "f"))
expect(res.hard == 0 and res.result == lines("a", "B", "c", "D", "E", "f"), "case 5 identical edits apply once: " .. res.result)

res = fix.resolve("", lines("mine"), lines("theirs"))
expect(res.hard == 1, "case 6 add/add is hard")

res = fix.resolve("a\nb\nc", "A\nb\nc", "a\nb\nC")
expect(res.hard == 0 and res.result == "A\nb\nC", "case 7 keeps a missing final newline")

res = fix.resolve(lines("a", "b", "c", "d"), lines("a", "b", "mid", "c", "d"), lines("a", "X", "d"))
expect(res.hard == 1, "case 8 insert inside a replaced range is hard")

res = fix.resolve("a\nb\n", "A\nb\n", "a\nb")
expect(res.hard == 0 and res.result == "A\nb", "case 9 keeps ours' final newline when only theirs dropped it: " .. vim.inspect(res.result))

res = fix.resolve("a\r\nb\r\nc\r\nd\r\n", "a\r\nB\r\nc\r\nd\r\n", "a\r\nb\r\nC\r\nd\r\n")
expect(res.hard == 0 and res.result == "a\r\nB\r\nC\r\nd\r\n", "case 10 keeps CRLF: " .. vim.inspect(res.result))

expect(fix.label('    "pr:brief": "bash x.sh",') == "pr:brief", "label takes the first quoted key")
expect(fix.label("  docker compose up") == "docker compose up", "label falls back to the trimmed line")

local stderr = table.concat({
  "Fetching origin\rremote: Counting objects: 100%",
  "hint: Updates were rejected because the tip is behind",
  "hint: its remote counterpart.",
  "fatal: could not read Username",
}, "\n") .. "\n"
expect(fix.git_error_line(stderr) == "fatal: could not read Username", "fatal wins over hint: " .. fix.git_error_line(stderr))
expect(fix.git_error_line("remote: x\rhint: y\nerror: failed to push some refs\nhint: z\n") == "error: failed to push some refs", "error wins over hint")
expect(fix.git_error_line("hint: a\nplain failure\n") == "plain failure", "first non-hint line as fallback")
expect(fix.git_error_line("") == "", "empty stderr")

print("unit ok")
vim.cmd("qa!")
LUA

nvim --headless "+luafile $tmp/unit.lua" +cquit 2>&1

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email "pr-fix-test@example.com"
git config --global user.name "PR Fix Test"
git config --global init.defaultBranch master
git config --global core.editor true
git config --global merge.ff only
git config --global pull.rebase true

cd "$tmp"
git init -q --bare remote.git
git clone -q remote.git main 2>/dev/null
cd main

mkdir scripts
cat > package.json <<'JSON'
{
  "scripts": {
    "format:check": "prettier --check .",
    "wt:sweep": "bash scripts/wt-sweep.sh",
    "preview": "bash scripts/preview.sh up",
    "test": "vitest"
  }
}
JSON
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'cd "$(dirname "$0")/.."' 'docker compose up -d api web' 'echo done' > scripts/preview.sh
printf '%s\n' 'name: ci' 'on: push' 'jobs:' '  build:' '    steps:' '      - run: npm test' '      - run: npm run lint' > ci.yml
printf '%s\n' 1 2 3 4 5 6 > f
printf 'a\r\nb\r\nc\r\nd\r\n' > crlf.txt
printf '%s\n' 1 2 3 > m.txt
echo 'm.txt conflict-marker-size=10' > .gitattributes
git add -A
git commit -qm "Initial"
git push -q origin master
base=$(git rev-parse HEAD)

branch() {
  git checkout -q -b "$1" "$base"
}
publish() {
  git commit -qam "$1"
  git push -q origin HEAD
}
sweep_line='$_ .= qq{    "%s": "echo %s",\n} if /wt:sweep/'

branch chore/reviewable-prs
perl -pi -e "$(printf "$sweep_line" pr:brief brief)" package.json
publish "chore: reviewable PRs"

branch feat/hard
perl -pi -e 's/api web$/api web worker/' scripts/preview.sh
perl -pi -e 's/npm test/npm run test:unit/' ci.yml
publish "feat: hard"

branch feat/dirty
perl -pi -e "$(printf "$sweep_line" dirty:check dirty)" package.json
publish "feat: dirty"

branch feat/nowt
perl -pi -e "$(printf "$sweep_line" nowt:check nowt)" package.json
publish "feat: nowt"

branch feat/parent
perl -pi -e 's/^2$/P/' f
publish "P1"
parent_sha=$(git rev-parse HEAD)

git checkout -q -b feat/stack
perl -pi -e 's/^3$/C/' f
publish "C1"
echo g > g.txt
git add g.txt
publish "C2"

git checkout -q "$base" 2>/dev/null
git checkout -q -b feat/stack2 feat/parent
echo g2 > g2.txt
git add g2.txt
publish "S2"

git checkout -q -b feat/skip feat/parent
perl -pi -e 's/^3$/S/' f
publish "K1"
echo k > s.txt
git add s.txt
publish "handle empty input"

branch feat/crlf
perl -pi -e 's/^b\r$/B\r/' crlf.txt
publish "feat: crlf"

branch feat/size
perl -pi -e 's/^2$/mine/' m.txt
publish "feat: size"

branch feat/div
echo d > div.txt
git add div.txt
publish "feat: div"

branch feat/nowt2
echo n > n2.txt
git add n2.txt
publish "feat: nowt2"

branch feat/entry
perl -pi -e "$(printf "$sweep_line" pr:entry entry)" package.json
publish "feat: entry"

git checkout -q master
perl -ni -e 'print unless /wt:sweep/' package.json
perl -pi -e 's/^c\r$/C\r/' crlf.txt
perl -pi -e 's/^2$/theirs/' m.txt
perl -pi -e 's/up -d api web/up -d --wait api web/' scripts/preview.sh
perl -pi -e 's/npm run lint/npm run lint:ci/' ci.yml
perl -pi -e 's/^2$/P/; s/^4$/4x/' f
publish "Remove sweep (#54)"

mkdir "$tmp/main-wt"
git worktree add -q "$tmp/main-wt/reviewable-prs" chore/reviewable-prs
git worktree add -q "$tmp/main-wt/hard" feat/hard
git worktree add -q "$tmp/main-wt/dirty" feat/dirty
git worktree add -q "$tmp/main-wt/stack" feat/stack
git worktree add -q "$tmp/main-wt/stack2" feat/stack2
git worktree add -q "$tmp/main-wt/skip" feat/skip
git worktree add -q "$tmp/main-wt/crlf" feat/crlf
git worktree add -q "$tmp/main-wt/size" feat/size
git worktree add -q "$tmp/main-wt/div" feat/div
git worktree add -q "$tmp/main-wt/entry" feat/entry
cd "$tmp"
git clone -q remote.git other 2>/dev/null

mkdir bin
cat > bin/gh <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time

args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")

def check(status, conclusion):
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return {"__typename": "CheckRun", "name": "CI", "status": status, "conclusion": conclusion,
            "startedAt": now, "completedAt": now if status == "COMPLETED" else None,
            "detailsUrl": "https://ci.example/run/1"}

def git_head(branch):
    return subprocess.check_output(["git", "--git-dir", os.environ["FAKE_GH_REMOTE"], "rev-parse", "refs/heads/" + branch], text=True).strip()

if args[:2] == ["pr", "view"] and args[2] == "80":
    print(json.dumps({"number": 80, "title": "PR 80", "body": "", "author": {"login": "me"}, "baseRefName": "master",
                      "headRefName": "feat/entry", "headRefOid": git_head("feat/entry"), "additions": 1, "deletions": 0,
                      "changedFiles": 1, "url": "https://github.com/o/r/pull/80", "isDraft": False, "state": "OPEN",
                      "mergeable": "CONFLICTING", "reviewDecision": "", "updatedAt": "2026-01-01T00:00:00Z",
                      "statusCheckRollup": [check("COMPLETED", "SUCCESS")]}))
elif args[:2] == ["pr", "view"]:
    number = args[2]
    branch = json.loads(os.environ["FAKE_GH_BRANCHES"])[number]
    head = subprocess.check_output(["git", "--git-dir", os.environ["FAKE_GH_REMOTE"], "rev-parse", "refs/heads/" + branch], text=True).strip()
    path = os.environ["FAKE_GH_STATE"]
    seen = json.load(open(path)) if os.path.exists(path) else {}
    seen[head] = seen.get(head, 0) + 1
    with open(path + ".tmp%d" % os.getpid(), "w") as out_file:
        json.dump(seen, out_file)
    os.replace(out_file.name, path)
    rollup = [] if seen[head] == 1 else [check("IN_PROGRESS", None)] if seen[head] == 2 else [check("COMPLETED", "SUCCESS")]
    print(json.dumps({"number": int(number), "headRefOid": head, "isDraft": number == "55", "statusCheckRollup": rollup}))
elif args[0] == "api" and "/branches/" in args[1]:
    print("m1")
elif args[0] == "api" and "/compare/" in args[1]:
    print(json.dumps({"count": 0, "subjects": []}))
elif args[:2] == ["pr", "checks"]:
    pass
else:
    sys.exit("fake gh: unhandled " + " ".join(args))
PY
chmod +x bin/gh

export TMP="$tmp" PARENT_SHA="$parent_sha"
export FAKE_GH_LOG="$tmp/gh.log" FAKE_GH_STATE="$tmp/gh-state.json" FAKE_GH_REMOTE="$tmp/remote.git"
export FAKE_GH_BRANCHES='{"80":"feat/entry","55":"chore/reviewable-prs","56":"feat/stack","57":"feat/hard","58":"feat/dirty","59":"feat/nowt"}'
touch "$tmp/gh.log"

cat > "$tmp/test.lua" <<'LUA'
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
vim.fn.confirm = function() error("confirm must not be called") end
vim.o.columns, vim.o.lines = 160, 50

local review = require("config.review_pr")
local fix = require("config.pr_fix")
local merges = require("config.merges")
review.settle_ms = 100

local tmp, parent_sha = vim.env.TMP, vim.env.PARENT_SHA
local main, remote = tmp .. "/main", tmp .. "/remote.git"

local function git(dir, ...)
  local out = vim.system(vim.list_extend({ "git" }, { ... }), { cwd = dir, text = true }):wait()
  return vim.trim(out.stdout or ""), out.code
end
local function log() return table.concat(vim.fn.readfile(vim.env.FAKE_GH_LOG), "\n") end
local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\nnotes:\n" .. table.concat(notes, "\n") .. "\ngh log:\n" .. log() .. "\n")
    vim.cmd("cquit 1")
  end
end
local function wait(cond, what, ms) expect(vim.wait(ms or 20000, cond, 50), "timeout: " .. what) end
local function remote_sha(branch) return (git(remote, "rev-parse", "refs/heads/" .. branch)) end
local function read(path) return table.concat(vim.fn.readfile(path), "\n") end
local function buffer() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end

local seen = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "PrMergesChanged",
  callback = function()
    for _, r in ipairs(review.merges) do
      if r.kind == "fix" then
        local states = seen[r] or {}
        seen[r] = states
        if states[#states] ~= r.state then states[#states + 1] = r.state end
      end
    end
  end,
})

local function item(number, icon, branch, extra)
  return vim.tbl_extend("force", { number = number, icon = icon, hl = "PrRed", text = "x", branch = branch, base = "master", title = "PR " .. number, fix = "cmd" }, extra or {})
end
local items = {
  [55] = item(55, "✗", "chore/reviewable-prs"),
  [56] = item(56, "↳", "feat/stack", { onto = parent_sha }),
  [57] = item(57, "✗", "feat/hard"),
  [58] = item(58, "✗", "feat/dirty"),
  [59] = item(59, "✗", "feat/nowt"),
  [60] = item(60, "✗", "feat/crlf"),
  [61] = item(61, "✗", "feat/size"),
  [62] = item(62, "✗", "feat/div"),
  [63] = item(63, "↳", "feat/stack2", { onto = parent_sha }),
  [64] = item(64, "↳", "feat/skip", { onto = parent_sha }),
  [65] = item(65, "✗", "feat/nowt2"),
}
local merged = {
  dir = main, number = 54, title = "Remove sweep", state = "merged", started = os.time(), finished = os.time(),
  fallout = { items[55], items[56], items[57], items[58], items[59] },
}
table.insert(review.merges, 1, merged)

local function tree_ok(path, head)
  expect((git(path, "rev-parse", "HEAD")) == head, path .. " HEAD unchanged")
  expect((git(path, "status", "--porcelain")) == "", path .. " clean")
  expect(select(2, git(path, "rev-parse", "-q", "--verify", "MERGE_HEAD")) ~= 0, path .. " no MERGE_HEAD")
end

-- git really conflicts on neighbouring edits
do
  local dir = tmp .. "/adjacent"
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q")
  vim.fn.writefile({ "a", "b", "c", "d" }, dir .. "/t")
  git(dir, "add", "t")
  git(dir, "commit", "-qm", "base")
  git(dir, "checkout", "-q", "-b", "left")
  vim.fn.writefile({ "a", "B", "c", "d" }, dir .. "/t")
  git(dir, "commit", "-qam", "left")
  git(dir, "checkout", "-q", "master")
  vim.fn.writefile({ "a", "b", "C", "d" }, dir .. "/t")
  git(dir, "commit", "-qam", "right")
  expect(select(2, git(dir, "merge", "-q", "left")) ~= 0, "git conflicts on adjacent edits")
end

-- probe
local heads = {}
local trees = { [55] = "reviewable-prs", [57] = "hard", [58] = "dirty" }
for number, name in pairs(trees) do heads[number] = (git(tmp .. "/main-wt/" .. name, "rev-parse", "HEAD")) end
fix.probe(merged)
wait(function() return items[55].probe and items[57].probe and items[58].probe and items[59].probe end, "probe")
expect(items[55].probe.note == "1 file · fix ready", "probe note: " .. items[55].probe.note)
expect(items[55].probe.sentence:find("#54 removed a line next to one #55 added", 1, true), "probe sentence: " .. items[55].probe.sentence)
expect(items[57].probe.note == "2 files · 1 needs you", "probe note: " .. items[57].probe.note)
expect(items[56].probe == nil, "stacked rows are not probed")
for number, name in pairs(trees) do tree_ok(tmp .. "/main-wt/" .. name, heads[number]) end

-- easy flow, through the dashboard
local branch_before = remote_sha("chore/reviewable-prs")
local r55 = fix.start(merged, items[55])
expect(fix.start(merged, items[55]) == r55, "a running fix is deduplicated")
wait(function() return r55.state == "resolving" end, "#55 resolving")
expect(vim.deep_equal(seen[r55], { "fetching", "merging", "resolving" }), "states: " .. vim.inspect(seen[r55]))
expect(r55.files[1].status == "ready" and r55.files[1].path == "package.json", "package.json proposal is ready")
expect(vim.uv.fs_stat(r55.gitdir .. "/MERGE_HEAD") ~= nil, "merge in progress")
expect(remote_sha("chore/reviewable-prs") == branch_before, "remote untouched while resolving")

merges.open(r55)
vim.wait(200)
local text = buffer()
for _, expected in ipairs({ "fix #55", "needs you", "package.json", "Result: keeps pr:brief, drops wt:sweep", "fixing ↑" }) do
  expect(text:find(expected, 1, true), "dashboard shows " .. expected .. "\n" .. text)
end
expect(merges.statusline():find("fix #55 needs you", 1, true), "statusline: " .. merges.statusline())
vim.cmd("normal a")
wait(function() return r55.state == "ready" end, "#55 ready")
expect(merges.statusline():find("fix #55 ready to push", 1, true), "statusline: " .. merges.statusline())
vim.cmd("normal q")

local wt55 = tmp .. "/main-wt/reviewable-prs"
local package = read(wt55 .. "/package.json")
expect(package:find("pr:brief", 1, true) and not package:find("wt:sweep", 1, true) and not package:find("<<<<", 1, true), "resolved package.json")
expect((git(wt55, "rev-list", "--parents", "-n1", "HEAD")) == table.concat({ r55.merge_sha, r55.orig, (git(wt55, "rev-parse", "origin/master")) }, " "), "merge commit parents")
fix.push(r55, true)
expect(r55.state == "ready", "p only for non-stacked, P ignored")
fix.push(r55, false)
wait(function() return r55.state == "fixed" end, "#55 fixed")
expect(remote_sha("chore/reviewable-prs") == (git(wt55, "rev-parse", "HEAD")), "pushed")
expect(select(2, git(remote, "merge-base", "--is-ancestor", branch_before, "refs/heads/chore/reviewable-prs")) == 0, "no force needed")
expect(r55.draft == true and not log():find("pr merge", 1, true), "never merges")
expect(select(2, git(tmp .. "/main", "rev-parse", "-q", "--verify", "refs/stash")) ~= 0, "no stash")

-- real conflict, undo from ready, abort mid-resolve
local wt57 = tmp .. "/main-wt/hard"
local r57 = fix.start(merged, items[57])
wait(function() return r57.state == "resolving" end, "#57 resolving")
local by_path = {}
for _, f in ipairs(r57.files) do by_path[f.path] = f end
expect(by_path["ci.yml"].status == "ready" and by_path["scripts/preview.sh"].status == "real", "file statuses")
merges.open(r57)
vim.wait(200)
text = buffer()
expect(text:find("scripts/preview.sh:4 · you decide", 1, true), "box shows the real conflict\n" .. text)
expect(text:find("master (#54)", 1, true) and text:find("up -d --wait api web", 1, true), "box shows both sides")
fix.accept(r57, by_path["ci.yml"])
wait(function() return by_path["ci.yml"].status == "accepted" end, "ci.yml accepted")
merges.open_file(r57, by_path["scripts/preview.sh"])
expect(vim.api.nvim_buf_get_name(0) == wt57 .. "/scripts/preview.sh", "opened the file")
expect(vim.api.nvim_get_current_line():match("^<<<<<<<"), "cursor on the marker: " .. vim.api.nvim_get_current_line())
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#!/usr/bin/env bash", "docker compose up -d --wait api web worker", "echo done" })
vim.cmd("silent write")
wait(function() return r57.state == "ready" end, "#57 ready after saving")
expect(by_path["scripts/preview.sh"].status == "resolved", "preview.sh resolved")
vim.cmd("bwipeout!")
fix.abort(r57)
wait(function() return r57.finished end, "#57 undone")
tree_ok(wt57, r57.orig)
expect(r57.state == "aborted" and r57.headline == "back at " .. r57.orig:sub(1, 7) .. " exactly", "undo headline: " .. tostring(r57.headline))

local again = fix.start(merged, items[57])
wait(function() return again.state == "resolving" end, "#57 resolving again")
fix.abort(again)
wait(function() return again.finished end, "#57 aborted mid-resolve")
tree_ok(wt57, again.orig)
expect(again.state == "aborted" and again.headline == "back at " .. again.orig:sub(1, 7) .. " exactly", "abort headline")

-- recovery after a restart
local before_restart = fix.start(merged, items[57])
wait(function() return before_restart.state == "resolving" end, "#57 resolving before restart")
local gitdir = before_restart.gitdir
review.merges = {}
fix.refresh(main)
local paused
wait(function()
  paused = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.state == "paused" and #r.files > 0 end)
  return paused
end, "paused record")
expect(paused.number == 57 and paused.orig == before_restart.orig, "paused record rebuilt")
expect(paused.lease == remote_sha("feat/hard") and paused.lease == before_restart.lease, "lease restored from the state file")
fix.resume(paused)
wait(function() return paused.state == "resolving" end, "paused resumes")
fix.abort(paused)
wait(function() return paused.finished end, "paused record aborted")
tree_ok(wt57, before_restart.orig)
expect(#vim.fn.glob(tmp .. "/main/.git/pr-fix/*.json", false, true) == 0, "state file removed")
table.insert(review.merges, 1, merged)

-- abort while the fix is still starting
local early = fix.start(merged, items[57])
fix.abort(early)
wait(function() return early.finished end, "#57 aborted while starting")
expect(early.state == "aborted" and early.headline == "nothing changed" and not early.aborting, "early abort: " .. tostring(early.headline))
tree_ok(wt57, before_restart.orig)
local starting = fix.start(merged, items[57])
wait(function() return starting.orig end, "#57 orig known")
fix.abort(starting)
wait(function() return starting.finished end, "#57 aborted once started")
expect(starting.state == "aborted" and not starting.aborting, "abort once started: " .. starting.state .. " " .. tostring(starting.reason))
tree_ok(wt57, before_restart.orig)

-- a failed fix leaves no state file behind
local doomed = fix.start(merged, vim.tbl_extend("force", items[57], { base = "nope" }))
wait(function() return doomed.finished end, "#57 fails")
expect(doomed.state == "failed" and doomed.reason:find("merge failed", 1, true), "doomed reason: " .. tostring(doomed.reason))
expect(#vim.fn.glob(tmp .. "/main/.git/pr-fix/*.json", false, true) == 0, "failed fix removed its state file")
fix.refresh(main)
vim.wait(500, function() return false end)
expect(not vim.iter(review.merges):any(function(r) return r.kind == "fix" and not r.finished end), "no phantom paused record")
expect(fix.latest(main, 57, doomed.started) == doomed and doomed.finished, "latest is the failed record")
tree_ok(wt57, before_restart.orig)

-- the same fix is found from any worktree of the repository
local live = fix.start(merged, items[57])
wait(function() return live.state == "resolving" end, "#57 resolving for dedupe")
expect(fix.start({ dir = wt57 }, items[57]) == live, "a running fix is found from its worktree")
expect(fix.latest(wt57, 57, 0) == live, "latest is found from a worktree")
fix.refresh(wt57)
vim.wait(500, function() return false end)
expect(#vim.tbl_filter(function(r) return r.kind == "fix" and r.number == 57 and not r.finished end, review.merges) == 1, "no duplicate record")
fix.abort(live)
wait(function() return live.finished end, "#57 aborted after dedupe")
tree_ok(wt57, before_restart.orig)

-- two refreshes in a row restore one record
local twice = fix.start(merged, items[57])
wait(function() return twice.state == "resolving" end, "#57 resolving before two refreshes")
review.merges = {}
fix.refresh(main)
fix.refresh(wt57)
wait(function() return #review.merges > 0 end, "restored once")
vim.wait(500, function() return false end)
expect(#vim.tbl_filter(function(r) return r.kind == "fix" and r.number == 57 end, review.merges) == 1, "one record after two refreshes")
local restored_once = review.merges[1]
wait(function() return not restored_once.busy end, "restored record idle")
fix.abort(restored_once)
wait(function() return restored_once.finished end, "restored record aborted")
tree_ok(wt57, before_restart.orig)
table.insert(review.merges, 1, merged)

-- dirty worktree
local wt58 = tmp .. "/main-wt/dirty"
vim.fn.writefile({ "scratch" }, wt58 .. "/notes.md")
vim.fn.writefile({ "1", "2", "3", "4", "5", "6 local" }, wt58 .. "/f")
local r58 = fix.start(merged, items[58])
wait(function() return r58.state == "dirty" end, "#58 dirty")
expect(vim.tbl_contains(r58.dirty, "?? notes.md"), "dirty lists untracked files: " .. vim.inspect(r58.dirty))
fix.stash(r58)
wait(function() return r58.state == "resolving" end, "#58 resolving after stash")
fix.accept(r58)
wait(function() return r58.state == "ready" end, "#58 ready")
expect(vim.uv.fs_stat(wt58 .. "/notes.md") ~= nil and read(wt58 .. "/f"):find("6 local", 1, true), "stashed changes are back")
expect((git(wt58, "stash", "list")) == "", "stash list is empty")
fix.abort(r58)
wait(function() return r58.finished end, "#58 undone")
expect(r58.state == "aborted" and r58.headline:find("stash restored", 1, true), "undo headline: " .. tostring(r58.headline))
expect((git(wt58, "rev-parse", "HEAD")) == r58.orig, "#58 back at the original commit")
expect(vim.uv.fs_stat(wt58 .. "/notes.md") ~= nil and read(wt58 .. "/f"):find("6 local", 1, true), "local changes survive the undo")
expect((git(wt58, "stash", "list")) == "", "stash list is empty after the undo")

local stashing = fix.start(merged, items[58])
wait(function() return stashing.state == "dirty" end, "#58 dirty again")
fix.stash(stashing)
fix.abort(stashing)
wait(function() return stashing.finished end, "#58 aborted during the stash")
expect(stashing.state == "aborted" and stashing.headline == "back at " .. stashing.orig:sub(1, 7) .. " exactly, stash restored", "stash abort headline: " .. tostring(stashing.headline))
expect(vim.uv.fs_stat(wt58 .. "/notes.md") ~= nil and read(wt58 .. "/f"):find("6 local", 1, true), "changes are back after aborting the stash")
expect((git(wt58, "stash", "list")) == "", "nothing left stashed")

-- a clean worktree never adopts the user's own stash
local adopt = fix.start(merged, items[58])
wait(function() return adopt.state == "dirty" end, "#58 dirty before the user stashes")
git(wt58, "stash", "push", "-u", "-m", "user work")
fix.stash(adopt)
wait(function() return adopt.state == "resolving" end, "#58 resolving without a stash")
expect(adopt.stash == nil and not adopt.stashed, "the user's stash is not adopted")
fix.abort(adopt)
wait(function() return adopt.finished end, "#58 aborted without a stash")
expect(adopt.headline == "back at " .. adopt.orig:sub(1, 7) .. " exactly", "no stash in the headline: " .. tostring(adopt.headline))
expect((git(wt58, "stash", "list")):find("user work", 1, true), "the user's stash is still there")
git(wt58, "stash", "pop")

-- a failure after the stash puts the changes back
local broke = fix.start(merged, vim.tbl_extend("force", items[58], { base = "nope" }))
wait(function() return broke.state == "dirty" end, "#58 dirty before the failure")
fix.stash(broke)
wait(function() return broke.finished end, "#58 fails after stashing")
expect(broke.state == "failed" and broke.reason:find("merge failed", 1, true), "broke reason: " .. tostring(broke.reason))
expect((git(wt58, "stash", "list")) == "", "stash popped after the failure")
expect(vim.uv.fs_stat(wt58 .. "/notes.md") ~= nil and read(wt58 .. "/f"):find("6 local", 1, true), "changes are back after the failure")
expect((git(wt58, "rev-parse", "HEAD")) == broke.orig, "#58 still at the original commit")

-- no worktree, rejected push, redo
local r59 = fix.start(merged, items[59])
wait(function() return r59.state == "no_worktree" end, "#59 has no worktree")
expect(r59.new_path == tmp .. "/main-wt/nowt", "new path: " .. tostring(r59.new_path))
fix.worktree(r59)
wait(function() return r59.state == "resolving" end, "#59 resolving in the new worktree")
expect((git(r59.new_path, "rev-parse", "--abbrev-ref", "HEAD")) == "feat/nowt", "worktree on the branch")
fix.accept(r59)
wait(function() return r59.state == "ready" end, "#59 ready")
local kept = (git(r59.new_path, "rev-parse", "HEAD"))
local other = tmp .. "/other"
git(other, "fetch", "-q", "origin")
git(other, "checkout", "-q", "-b", "feat/nowt", "origin/feat/nowt")
vim.fn.writefile({ "other" }, other .. "/other.txt")
git(other, "add", "other.txt")
git(other, "commit", "-qm", "someone else")
git(other, "push", "-q", "origin", "feat/nowt")
fix.push(r59, false)
wait(function() return r59.finished end, "#59 push rejected")
expect(r59.state == "failed" and r59.reason == "push rejected: the branch moved on GitHub", "rejected: " .. tostring(r59.reason))
expect(r59.note == "Merge commit kept locally · f fetch and redo", "rejected note")
expect((git(r59.new_path, "rev-parse", "HEAD")) == kept, "merge commit kept")
local redo = fix.redo(r59)
local for_59 = vim.tbl_filter(function(r) return r.kind == "fix" and r.number == 59 end, review.merges)
expect(#for_59 == 1 and for_59[1] == redo, "redo replaces the failed record: " .. #for_59)
expect(not vim.tbl_contains(review.merges, r59), "failed record removed")
wait(function() return redo.state == "resolving" end, "#59 redo resolving")
expect((git(redo.path, "log", "--format=%s", "-1", "origin/feat/nowt")) == "someone else", "redo fetched the new commit")
fix.abort(redo)
wait(function() return redo.finished end, "#59 redo aborted")
expect((git(redo.path, "rev-parse", "HEAD")) == r59.orig, "redo abort goes back to the original commit")

local r65 = fix.start(merged, items[65])
wait(function() return r65.state == "no_worktree" end, "#65 has no worktree")
fix.worktree(r65)
fix.abort(r65)
wait(function() return r65.finished end, "#65 aborted during worktree add")
expect(r65.state == "aborted" and r65.headline == "worktree created, nothing else changed", "worktree abort headline: " .. tostring(r65.headline))
expect(vim.uv.fs_stat(r65.new_path .. "/.git") ~= nil and (git(r65.new_path, "rev-parse", "HEAD")) == remote_sha("feat/nowt2"), "worktree exists on the branch")
tree_ok(r65.new_path, remote_sha("feat/nowt2"))

-- stacked
local wt56 = tmp .. "/main-wt/stack"
local r56 = fix.start(merged, items[56])
merges.open(r56)
expect(buffer():find("rebase --onto master", 1, true), "stacked chips render while starting\n" .. buffer())
vim.cmd("normal q")
wait(function() return r56.state == "resolving" end, "#56 resolving")
review.merges = {}
fix.refresh(main)
wait(function()
  r56 = vim.iter(review.merges):find(function(r) return r.kind == "fix" and r.state == "paused" and #r.files > 0 end)
  return r56
end, "stacked paused record")
merges.open(r56)
expect(buffer():find("paused", 1, true), "paused stacked record renders")
vim.cmd("normal q")
fix.resume(r56)
wait(function() return r56.state == "resolving" and r56.total == 2 and not r56.busy and #r56.files == 1 end, "stacked resume rebuilds the rebase")
merges.open(r56)
expect(buffer():find("rebase --onto master 1/2", 1, true), "resumed stacked chips\n" .. buffer())
expect(buffer():find("C2", 1, true), "resumed stacked commit rows")
vim.cmd("normal q")
table.insert(review.merges, 1, merged)
wait(function() return not r56.busy end, "#56 idle")
expect(#r56.commits == 2 and r56.commits[1].status == "current", "commit rows: " .. vim.inspect(r56.commits))
fix.accept(r56)
wait(function() return r56.state == "ready" end, "#56 ready")
expect((git(wt56, "rev-list", "--count", "origin/master..HEAD")) == "2", "exactly the two child commits")
expect(r56.commits[1].status == "done" and r56.commits[1].note == "1 conflict, fix accepted", "commit notes: " .. vim.inspect(r56.commits))
fix.push(r56, false)
expect(r56.state == "ready", "p refused for stacked")
fix.push(r56, true)
wait(function() return r56.state == "fixed" end, "#56 fixed")
expect(remote_sha("feat/stack") == (git(wt56, "rev-parse", "HEAD")), "force-pushed")

-- an untracked file that blocks a pick is reported, never skipped
local r64 = fix.start(merged, items[64])
wait(function() return r64.state == "resolving" end, "#64 resolving")
vim.fn.writefile({ "blocker" }, r64.path .. "/s.txt")
fix.accept(r64)
wait(function() return r64.finished end, "#64 stops")
expect(r64.state == "failed" and r64.reason:find("rebase failed", 1, true) and (r64.skips or 0) == 0, "blocked pick reason: " .. tostring(r64.reason))
expect(vim.uv.fs_stat(r64.gitdir .. "/rebase-merge") ~= nil, "rebase left in progress")
expect(#vim.fn.glob(tmp .. "/main/.git/pr-fix/*.json", false, true) == 0, "state file removed after the failure")
os.remove(r64.path .. "/s.txt")
git(r64.path, "rebase", "--abort")
tree_ok(r64.path, r64.orig)

-- CRLF files keep their line endings
local r60 = fix.start(merged, items[60])
wait(function() return r60.state == "resolving" end, "#60 resolving")
expect(r60.files[1].status == "ready", "crlf proposal is ready")
fix.accept(r60)
wait(function() return r60.state == "ready" end, "#60 ready")
local crlf = io.open(r60.path .. "/crlf.txt", "rb"):read("*a")
expect(crlf == "a\r\nB\r\nC\r\nd\r\n", "crlf bytes kept: " .. vim.inspect(crlf))
fix.abort(r60)
wait(function() return r60.finished end, "#60 undone")

-- conflict-marker-size is honoured
local r61 = fix.start(merged, items[61])
wait(function() return r61.state == "resolving" end, "#61 resolving")
expect(read(r61.path .. "/m.txt"):find("<<<<<<<<<< ", 1, true), "git wrote size 10 markers")
fix.rescan(r61)
vim.wait(500, function() return false end)
expect(r61.state == "resolving" and r61.files[1].status == "real" and r61.files[1].markers > 0, "markers still count")
expect(vim.uv.fs_stat(r61.gitdir .. "/MERGE_HEAD") ~= nil, "nothing committed")
fix.abort(r61)
wait(function() return r61.finished end, "#61 undone")
tree_ok(r61.path, r61.orig)

-- a diverged branch is never pushed
local function diverge(branch, name)
  local wt = tmp .. "/main-wt/" .. name
  vim.fn.writefile({ "mine" }, wt .. "/mine.txt")
  git(wt, "add", "mine.txt")
  git(wt, "commit", "-qm", "local only")
  git(other, "fetch", "-q", "origin")
  git(other, "checkout", "-q", "-B", branch, "origin/" .. branch)
  vim.fn.writefile({ "theirs" }, other .. "/theirs-" .. name .. ".txt")
  git(other, "add", "-A")
  git(other, "commit", "-qm", "teammate")
  git(other, "push", "-q", "origin", branch)
  return remote_sha(branch)
end
local teammate = diverge("feat/div", "div")
local r62 = fix.start(merged, items[62])
wait(function() return r62.state == "ready" end, "#62 ready")
expect(r62.diverged, "divergence recorded")
fix.push(r62, false)
expect(r62.state == "failed" and r62.reason == "branch diverged: origin/feat/div has commits not in this branch", "diverged reason: " .. tostring(r62.reason))
expect(remote_sha("feat/div") == teammate, "teammate commits untouched")
expect(#vim.fn.glob(tmp .. "/main/.git/pr-fix/*.json", false, true) == 0, "diverged fix removed its state file")

local teammate2 = diverge("feat/stack2", "stack2")
local r63 = fix.start(merged, items[63])
wait(function() return r63.state == "ready" end, "#63 ready")
fix.push(r63, true)
expect(r63.state == "failed" and r63.reason:find("branch diverged", 1, true), "stacked diverged reason: " .. tostring(r63.reason))
expect(remote_sha("feat/stack2") == teammate2 and not log():find("force-with-lease", 1, true), "teammate commits untouched by P")

-- merge on a conflicting PR, then f from the refused record
local entry = review.merge_pr(main, 80, { title = "PR 80" })
wait(function() return entry.finished end, "#80 refused")
expect(entry.state == "refused" and entry.conflict and entry.reason == "conflicts with master · f fix", "refused for conflict: " .. tostring(entry.reason))
merges.open(entry)
vim.wait(100)
expect(vim.api.nvim_get_current_line():find("#80", 1, true), "cursor on the refused record")
vim.cmd("normal f")
local entry_fix
wait(function()
  entry_fix = fix.latest(main, 80, 0)
  return entry_fix and entry_fix.state == "resolving"
end, "#80 fix resolving")
expect(entry_fix.from == nil and entry_fix.branch == "feat/entry", "fix started from the refused record")
vim.wait(200)
expect(buffer():find("fix #80", 1, true), "dashboard shows the fix\n" .. buffer())
fix.accept(entry_fix)
wait(function() return entry_fix.state == "ready" end, "#80 ready")
vim.wait(200)
expect(buffer():find("Merge commit", 1, true), "ready box renders without a parent PR\n" .. buffer())
fix.abort(entry_fix)
wait(function() return entry_fix.finished end, "#80 undone")
vim.cmd("normal q")

-- a failing commit hook goes back to where the fix started
local hook = tmp .. "/main/.git/hooks/pre-commit"
vim.fn.writefile({ "#!/bin/sh", "echo hook says no >&2", "exit 1" }, hook)
vim.fn.setfperm(hook, "rwxr-xr-x")
local hooked = fix.start(merged, item(80, "✗", "feat/entry"))
wait(function() return hooked.state == "resolving" and not hooked.busy end, "#80 resolving for the hook")
fix.accept(hooked)
wait(function() return hooked.finished end, "#80 fails on the hook")
os.remove(hook)
expect(hooked.state == "failed" and hooked.reason:find("commit failed", 1, true) and hooked.note == "nothing changed", "hook failure: " .. tostring(hooked.reason) .. " / " .. tostring(hooked.note))
tree_ok(hooked.path, hooked.orig)
expect(#vim.fn.glob(tmp .. "/main/.git/pr-fix/*.json", false, true) == 0, "hook failure removed its state file")
local retried = fix.redo(hooked)
wait(function() return retried.state == "resolving" end, "redo after the hook failure")
fix.abort(retried)
wait(function() return retried.finished end, "redo aborted")

-- a push without a known lease is refused
local nolease = {
  kind = "fix", dir = main, number = 90, title = "x", branch = "feat/stack2", base = "master", stacked = parent_sha, state = "ready", step = "push",
  started = os.time(), files = {}, commits = {}, contains = {}, merge_sha = "abc",
}
table.insert(review.merges, 1, nolease)
fix.push(nolease, true)
expect(nolease.state == "failed" and nolease.reason == "lease unknown, f to redo", "lease unknown: " .. tostring(nolease.reason))
table.remove(review.merges, 1)

-- ^b on a fix in CI opens the checks
local in_ci = { kind = "fix", dir = main, number = 77, title = "ci", branch = "x", base = "master", state = "ci", step = "ci", started = os.time(), files = {}, commits = {} }
table.insert(review.merges, 1, in_ci)
merges.open(in_ci)
vim.wait(100)
vim.cmd([[execute "normal \<C-b>"]])
wait(function() return log():find("pr checks 77 --web", 1, true) end, "checks opened")
table.remove(review.merges, 1)
vim.cmd("normal q")

local stray = vim.tbl_filter(function(note) return not note:match("^Copied:") end, notes)
expect(#stray == 0, "no notifications from the fix flow: " .. table.concat(stray, " | "))

print("ok")
vim.cmd("qa!")
LUA

PATH="$tmp/bin:$PATH" nvim --headless "+cd $tmp/main" "+luafile $tmp/test.lua" +cquit 2>&1
