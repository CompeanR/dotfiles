#!/usr/bin/env bash
# Merge flow of nvim/lua/config/review_pr.lua against a fake `gh`:
# stale CI -> update branch -> wait for CI -> merge pinned to the new head,
# (checks attach late), then the fallout report (stacked child, a PR that now
# conflicts), a refused conflicting PR and a PR whose checks never finish.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
git init -q
git config user.email "review-pr-test@example.com"
git config user.name "Review PR Test"
git commit -q --allow-empty -m initial

mkdir bin
cat > bin/gh <<'PY'
#!/usr/bin/env python3
import json, os, sys, time

state_path = os.environ["FAKE_GH_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")

now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
prs = state["prs"]

def save():
    json.dump(state, open(state_path, "w"))

def out(value):
    print(json.dumps(value))

def check(status, conclusion, started):
    return {"__typename": "CheckRun", "name": "CI", "status": status, "conclusion": conclusion,
            "startedAt": started, "completedAt": started if status == "COMPLETED" else None}

if args[:2] == ["pr", "view"]:
    pr = prs[args[2]]
    if pr.get("attach_after", 0) > 0:
        pr["attach_after"] -= 1
        if pr["attach_after"] == 0:
            pr["statusCheckRollup"] = [check("IN_PROGRESS", None, now)]
        save()
    out(pr)
elif args[:2] == ["pr", "list"]:
    base = args[args.index("--base") + 1] if "--base" in args else None
    found = [p for p in prs.values() if p["state"] == "OPEN" and (base is None or p["baseRefName"] == base)]
    if base == "master" and state.get("unknown_polls", 0) > 0:
        state["unknown_polls"] -= 1
        found = [dict(p, mergeable="UNKNOWN") if p["number"] == 62 else p for p in found]
        save()
    out(found)
elif args[0] == "api" and "/branches/" in args[1]:
    print(state["base_time"])
elif args[:2] == ["pr", "update-branch"]:
    pr = prs[args[2]]
    pr["headRefOid"] = "bbbbbbbbbbbbbbbbbbbb"
    pr["statusCheckRollup"] = []
    pr["attach_after"] = 2
    save()
elif args[:2] == ["pr", "checks"]:
    pr = prs[args[2]]
    if not pr.get("sticky"):
        pr["statusCheckRollup"] = [check("COMPLETED", "SUCCESS", now)]
        save()
elif args[:2] == ["pr", "merge"]:
    pr = prs[args[2]]
    pr["state"] = "MERGED"
    state["base_time"] = now
    for p in prs.values():
        if p["baseRefName"] == pr["headRefName"]:
            p["baseRefName"] = pr["baseRefName"]
    prs["62"]["mergeable"] = "CONFLICTING"
    state["unknown_polls"] = 1
    save()
else:
    sys.exit("fake gh: unhandled " + " ".join(args))
PY
chmod +x bin/gh

python3 - "$tmp/state.json" <<'PY'
import json, sys
old = "2026-01-01T00:00:00Z"
def pr(number, head, base, mergeable="MERGEABLE"):
    return {"number": number, "title": "PR %d" % number, "body": "", "author": {"login": "me"},
            "baseRefName": base, "headRefName": head, "headRefOid": "a%d" % number, "additions": 1,
            "deletions": 0, "changedFiles": 1, "url": "https://github.com/o/r/pull/%d" % number,
            "isDraft": False, "state": "OPEN", "mergeable": mergeable, "reviewDecision": "",
            "updatedAt": old, "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI",
            "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": old, "completedAt": old}]}
state = {"base_time": "2026-02-01T00:00:00Z", "prs": {
    "60": pr(60, "feat/a", "master"),
    "61": pr(61, "feat/b", "feat/a"),
    "62": pr(62, "feat/c", "master"),
    "63": pr(63, "feat/d", "master"),
    "64": pr(64, "feat/e", "master", "CONFLICTING"),
    "65": pr(65, "feat/f", "master"),
    "67": pr(67, "feat/h", "master"),
    "66": pr(66, "feat/g", "dev", "UNKNOWN"),
}}
state["prs"]["65"]["statusCheckRollup"][0]["startedAt"] = "2026-03-01T00:00:00Z"
state["prs"]["63"]["sticky"] = True
state["prs"]["63"]["statusCheckRollup"] = [{"__typename": "StatusContext", "context": "ci/ext",
                                            "state": "EXPECTED", "startedAt": old}]
json.dump(state, open(sys.argv[1], "w"))
PY

cat > test.lua <<'LUA'
local notes, prompts, done = {}, {}, false
vim.notify = function(msg) notes[#notes + 1] = msg end
local answers = { 1 }
vim.fn.confirm = function(msg)
  prompts[#prompts + 1] = msg
  return table.remove(answers, 1) or 2
end

local review_pr = require("config.review_pr")
review_pr.settle_ms = 100
review_pr.merge_pr(vim.uv.cwd(), 60, {}, function() done = true end)
vim.wait(20000, function()
  return done and vim.iter(notes):any(function(n) return n:match("^After #60") end)
end, 200)

local all = table.concat(notes, "\n---\n")
local log = table.concat(vim.fn.readfile(vim.env.FAKE_GH_LOG), "\n")
local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\nnotes:\n" .. all .. "\nprompts:\n" .. table.concat(prompts, "\n---\n")
      .. "\ngh log:\n" .. log .. "\n")
    vim.cmd("cquit 1")
  end
end

expect(prompts[1] and prompts[1]:match("CI ran before master moved"), "stale CI prompt")
expect(prompts[1]:match("Stacked on this PR: #61"), "stacked warning in the prompt")
expect(#prompts == 1, "no second confirmation after choosing update")
expect(log:match("pr update%-branch 60"), "branch updated")
expect(log:match("pr checks 60 %-%-watch"), "waited for CI")
expect(log:match("pr merge 60 %-%-squash %-%-match%-head%-commit bbbbbbbbbbbbbbbbbbbb"), "merge pinned to the new head")
expect(log:find("pr checks 60", 1, true) < log:find("pr merge 60", 1, true), "merged only after CI was watched")
expect(all:match("#61 was stacked on #60: git fetch && git switch 'feat/b' && git rebase %-%-onto 'origin/master' bbbbbbbbbbbb"),
  "stacked fix in the report")
expect(all:match("#62 conflicts with master: git fetch && git switch 'feat/c' && git rebase 'origin/master'"),
  "conflict fix in the report")
expect(not all:match("CI ran before this merge:[^\n]*#67"), "PR whose CI was already stale is not flagged")
expect(not all:match("#64 conflicts"), "conflict that already existed not reported")
expect(all:match("CI ran before this merge: #65\n") or all:match("CI ran before this merge: #65$"),
  "only the PR whose CI this merge made stale is flagged")
local before = #notes
review_pr.merge_pr(vim.uv.cwd(), 62, {}, function() end)
vim.wait(10000, function() return #notes > before end, 100)
expect(notes[#notes]:match("Not merging #62: conflicts with master%. Fix: git fetch && git switch 'feat/c'"),
  "conflicting PR refused with its fix")
expect(#prompts == 1, "no prompt for a conflicting PR")

answers = { 1 }
review_pr.merge_pr(vim.uv.cwd(), 63, {}, function() end)
review_pr.merge_pr(vim.uv.cwd(), 63, {}, function() end)
expect(notes[#notes]:match("already in progress"), "second merge of the same PR refused")
vim.wait(10000, function() return notes[#notes]:match("Not merging #63") end, 100)
expect(notes[#notes]:match("Not merging #63: checks are still running"), "bounded wait when checks never finish")
expect(not table.concat(vim.fn.readfile(vim.env.FAKE_GH_LOG), "\n"):match("pr merge 63"), "PR with unfinished checks not merged")

before = #notes
review_pr.merge_pr(vim.uv.cwd(), 66, {}, function() end)
vim.wait(10000, function() return notes[#notes]:match("Not merging #66") end, 100)
expect(notes[before + 1]:match("Waiting for GitHub to settle #66"), "notice when the wait starts")
expect(notes[#notes]:match("Not merging #66: GitHub has not computed conflicts yet"), "UNKNOWN wait refuses")
expect(not table.concat(vim.fn.readfile(vim.env.FAKE_GH_LOG), "\n"):match("pr merge 66"), "UNKNOWN PR never merged")

before = #notes
review_pr.merge_pr(vim.uv.cwd(), 66, {}, function() end)
expect(notes[before + 1] == nil or not notes[before + 1]:match("already in progress"), "flag cleared after a refusal")
vim.wait(10000, function() return notes[#notes]:match("Not merging #66") and #notes > before + 1 end, 100)

if vim.env.DEBUG then print(all .. "\n===\n" .. table.concat(prompts, "\n---\n") .. "\n===\n" .. log) end
print("ok")
vim.cmd("qa!")
LUA

PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/state.json" FAKE_GH_LOG="$tmp/gh.log" \
  nvim --headless "+cd $tmp" "+luafile $tmp/test.lua" 2>&1
