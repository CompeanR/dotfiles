#!/usr/bin/env bash
# Merge flow of nvim/lua/config/review_pr.lua and the merges dashboard against a
# fake `gh`: behind master -> ask -> update or merge as tested -> wait for CI ->
# merge pinned to the head, the fallout report, refusals, failures, cancel and
# timeouts, and the dashboard/statusline.
set -euo pipefail

tmp=$(mktemp -d)
cleanup() {
  for _ in 1 2 3 4 5; do
    rm -rf "$tmp" 2>/dev/null && return
    sleep 0.5
  done
}
trap cleanup EXIT

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
master = state["master"]

def save():
    with open(state_path + ".tmp%d" % os.getpid(), "w") as out_file:
        json.dump(state, out_file)
    os.replace(out_file.name, state_path)

def out(value):
    print(json.dumps(value))

def check(status, conclusion, started):
    return {"__typename": "CheckRun", "name": "CI", "status": status, "conclusion": conclusion,
            "startedAt": started, "completedAt": started if status == "COMPLETED" else None,
            "detailsUrl": "https://ci.example/run/1"}

def behind(pr):
    return len(master) - pr["base_at"] if "base_at" in pr else 0

if args[:2] == ["pr", "view"] and "mergeCommit" in args:
    print("c0ffee1234567890")
elif args[:2] == ["pr", "view"]:
    pr = prs[args[2]]
    rollup = pr["statusCheckRollup"]
    if pr.get("attach_after", 0) > 0:
        pr["attach_after"] -= 1
        if pr["attach_after"] == 0:
            pr["statusCheckRollup"] = [check("IN_PROGRESS", None, now)]
    elif rollup and rollup[0].get("status") == "IN_PROGRESS":
        for key, conclusion in (("pass_after", "SUCCESS"), ("fail_after", "FAILURE")):
            if key in pr:
                pr[key] -= 1
                if pr[key] <= 0:
                    del pr[key]
                    pr["statusCheckRollup"] = [check("COMPLETED", conclusion, now)]
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
    print("m%d" % len(master))
elif args[0] == "api" and "/compare/" in args[1]:
    head = args[1].split("/compare/")[1].split("...")[0]
    found = [p for p in prs.values() if p["headRefOid"] == head]
    count = behind(found[0]) if found else 0
    out({"count": count, "subjects": master[:count]})
elif args[:2] == ["pr", "update-branch"]:
    pr = prs[args[2]]
    if pr.get("update_fails"):
        sys.exit("update refused")
    pr["headRefOid"] = "b" * 18 + "%02d" % pr["number"]
    pr["base_at"] = len(master)
    pr["statusCheckRollup"] = []
    pr["attach_after"] = 2
    save()
elif args[:2] == ["pr", "ready"]:
    prs[args[2]]["isDraft"] = False
    save()
elif args[:2] == ["pr", "merge"]:
    pr = prs[args[2]]
    pr["state"] = "MERGED"
    master.insert(0, "%s (#%d)" % (pr["title"], pr["number"]))
    for p in prs.values():
        if p["baseRefName"] == pr["headRefName"]:
            p["baseRefName"] = pr["baseRefName"]
    if pr.get("conflicts_62"):
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
def success():
    return [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS",
             "startedAt": old, "completedAt": old}]
def pending():
    return [{"__typename": "CheckRun", "name": "CI", "status": "IN_PROGRESS", "conclusion": None,
             "startedAt": "2026-01-01T00:00:00Z", "completedAt": None}]
def failed(url=None):
    check = {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE",
             "startedAt": old, "completedAt": old}
    if url:
        check["detailsUrl"] = url
    return [check]
def sticky():
    return [{"__typename": "StatusContext", "context": "ci/ext", "state": "EXPECTED", "startedAt": old}]
def pr(number, head, base="master", mergeable="MERGEABLE", rollup=None, **extra):
    data = {"number": number, "title": "PR %d" % number, "body": "", "author": {"login": "me"},
            "baseRefName": base, "headRefName": head, "headRefOid": "a%d" % number, "additions": 1,
            "deletions": 0, "changedFiles": 1, "url": "https://github.com/o/r/pull/%d" % number,
            "isDraft": False, "state": "OPEN", "mergeable": mergeable, "reviewDecision": "",
            "updatedAt": old, "statusCheckRollup": success() if rollup is None else rollup}
    data.update(extra)
    return data
prs = [
    pr(60, "feat/a", base_at=0, conflicts_62=True, pass_after=2),
    pr(61, "feat/b", "feat/a"),
    pr(62, "feat/c"),
    pr(63, "feat/d", rollup=sticky()),
    pr(64, "feat/e", mergeable="CONFLICTING"),
    pr(65, "feat/f", base_at=0),
    pr(66, "feat/g", "dev", "UNKNOWN"),
    pr(68, "feat/i", isDraft=True),
    pr(69, "feat/j", base_at=0),
    pr(70, "feat/k"),
    pr(71, "feat/l", rollup=pending(), pass_after=2),
    pr(72, "feat/m", base_at=0, fail_after=1),
    pr(73, "feat/n", rollup=sticky()),
    pr(74, "feat/o", base_at=0, pass_after=1),
    pr(75, "feat/p", base_at=0),
    pr(76, "feat/r", base_at=0, update_fails=True),
    pr(77, "feat/s", rollup=failed("https://ci.example/run/77")),
    pr(78, "feat/t", rollup=failed()),
]
json.dump({"master": ["Add x (#53)"], "prs": {str(p["number"]): p for p in prs}}, open(sys.argv[1], "w"))
PY

cat > test.lua <<'LUA'
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
vim.fn.confirm = function() error("confirm must not be called") end

local review = require("config.review_pr")
local merges = require("config.merges")
review.settle_ms = 100
local dir = vim.uv.cwd()

local seen = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "PrMergesChanged",
  callback = function()
    for _, m in ipairs(review.merges) do
      seen[m.number] = seen[m.number] or { states = {}, details = {} }
      local entry = seen[m.number]
      if entry.states[#entry.states] ~= m.state then entry.states[#entry.states + 1] = m.state end
      if m.detail then entry.details[#entry.details + 1] = m.detail end
    end
  end,
})

local function log() return table.concat(vim.fn.readfile(vim.env.FAKE_GH_LOG), "\n") end
local function expect(ok, what)
  if not ok then
    io.stderr:write("FAIL: " .. what .. "\nnotes:\n" .. table.concat(notes, "\n") .. "\ngh log:\n" .. log() .. "\n")
    vim.cmd("cquit 1")
  end
end
local function wait(cond, what, ms)
  expect(vim.wait(ms or 20000, cond, 50), "timeout: " .. what)
end
local function has_state(n, state)
  return vim.tbl_contains((seen[n] or { states = {} }).states, state)
end
local function fake(fn)
  local path = vim.env.FAKE_GH_STATE
  local state = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  fn(state)
  vim.fn.writefile({ vim.json.encode(state) }, path .. ".lua")
  vim.uv.fs_rename(path .. ".lua", path)
end

local m = review.merge_pr(dir, 60, { title = "PR 60" })
wait(function() return m.state == "asking" end, "#60 asking")
expect(m.step == "behind" and m.detail == nil, "asking sits on the behind step")
expect(m.behind.count == 1 and vim.deep_equal(m.behind.refs, { "#53" }), "behind count and refs")
expect(not log():match("pr merge 60"), "nothing merged while asking")
review.answer_merge(m, "update")
wait(function() return m.fallout ~= nil and m.sha ~= nil end, "#60 merged with fallout", 40000)
local gh = log()
expect(m.state == "merged", "#60 merged")
expect(m.answered == "update" and m.updated_with == "#53", "updated with #53")
expect(gh:find("pr update-branch 60", 1, true) < gh:find("pr merge 60", 1, true), "updated before merging")
expect(gh:match("pr merge 60 %-%-squash %-%-match%-head%-commit bbbbbbbbbbbbbbbbbb60"), "merge pinned to the updated head")
expect(has_state(60, "ci"), "CI state observed")
expect(m.sha == "c0ffee1", "short merge sha")
local items = {}
for _, item in ipairs(m.fallout) do items[item.number] = item end
expect(items[61] and items[61].icon == "↳"
  and items[61].fix:match("git rebase %-%-onto 'origin/master' bbbbbbbbbbbb"), "stacked fix in the fallout")
expect(items[62] and items[62].text == "now conflicts with master"
  and items[62].fix:match("git worktree add '[^']*%-wt/c' 'feat/c' && cd '[^']*' && git merge 'origin/master' && git push$"), "conflict fix in the fallout")
expect(items[65] and items[65].icon == "↓" and items[65].text:match("#60"), "behind PR lists the merged PR")
expect(not items[64], "conflict that already existed not reported")
expect(review.unseen == m, "finished merge is unseen")

expect(merges.statusline() == "✓ #60 merged", "statusline after merge")
merges.open(m)
expect(merges.statusline() == "", "statusline cleared once the dashboard opens")
local buffer = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
for _, text in ipairs({ "done today", "#60", "changed for other PRs", "62  ✗ now conflicts with master" }) do
  expect(buffer:find(text, 1, true), "dashboard shows " .. text)
end

local live = review.merge_pr(dir, 74, { title = "PR 74" })
merges.open(live)
wait(function() return live.state == "asking" end, "#74 asking")
expect(merges.statusline() == " 1 · #74 needs you", "statusline while asking: " .. merges.statusline())
vim.wait(200)
expect(vim.api.nvim_get_current_line():match("#74"), "cursor on the new record")
vim.cmd("normal u")
wait(function() return live.state == "merged" end, "#74 merged from the dashboard")
vim.cmd("normal q")

local tested = review.merge_pr(dir, 69, { title = "PR 69" })
wait(function() return tested.state == "asking" end, "#69 asking")
review.answer_merge(tested, "tested")
wait(function() return tested.state == "merged" end, "#69 merged as tested")
gh = log()
expect(tested.answered == "tested", "answered tested")
expect(not gh:match("update%-branch 69"), "no branch update when merging as tested")
expect(gh:match("pr merge 69 %-%-squash %-%-match%-head%-commit a69"), "merge pinned to the original head")

local ready = review.merge_pr(dir, 70, { title = "PR 70" })
wait(function() return ready.state == "merged" end, "#70 merged")
expect(not has_state(70, "asking"), "up to date PR is never asked")

local waiting = review.merge_pr(dir, 71, { title = "PR 71" })
wait(function() return waiting.state == "merged" end, "#71 merged")
expect(has_state(71, "ci"), "pending CI observed")
expect(vim.iter(seen[71].details):any(function(d) return d:match("merges by itself when green") end), "CI detail text")

fake(function(state)
  state.master = { "Add x (#53)" }
  state.prs["72"].base_at = 0
end)
local broken = review.merge_pr(dir, 72, { title = "PR 72" })
wait(function() return broken.state == "asking" end, "#72 asking")
review.answer_merge(broken, "update")
wait(function() return broken.finished end, "#72 finished")
expect(broken.state == "failed" and broken.reason == "CI failed with #53: CI", "CI failure reason: " .. tostring(broken.reason))
expect(broken.note:match("Passed before the update, so #53 likely broke it"), "failure note")
expect(broken.log_url == "https://ci.example/run/1", "failed log url")
expect(not log():match("pr merge 72"), "failed CI never merged")

local draft = review.merge_pr(dir, 68, { title = "PR 68" })
wait(function() return draft.finished end, "#68 refused")
expect(draft.state == "refused" and draft.reason == "draft · nothing started" and draft.draft, "draft refused")
local conflicting = review.merge_pr(dir, 62, { title = "PR 62" })
wait(function() return conflicting.finished end, "#62 refused")
expect(conflicting.state == "refused" and conflicting.reason == "conflicts with master · f fix" and conflicting.conflict, "conflict refused")
expect(conflicting.fix:match("git merge 'origin/master'"), "refused conflict carries its fix")
expect(not log():match("pr merge 62"), "refused PRs never merged")

local unupdatable = review.merge_pr(dir, 76, { title = "PR 76" })
wait(function() return unupdatable.state == "asking" end, "#76 asking")
review.answer_merge(unupdatable, "update")
wait(function() return unupdatable.finished end, "#76 finished")
expect(unupdatable.state == "failed" and unupdatable.reason:match("^could not update with master: update refused"), "update failure reason: " .. tostring(unupdatable.reason))
expect(unupdatable.fix:match("git merge 'origin/master'"), "update failure carries the fix command")

local stuck = review.merge_pr(dir, 66, { title = "PR 66" })
wait(function() return stuck.finished end, "#66 gave up")
expect(vim.iter(seen[66].details):any(function(d) return d:match("Asks every") end), "settle detail")
expect(stuck.state == "failed" and stuck.reason:match("GitHub is computing conflicts · gave up at"), "settle timeout reason")
expect(not log():match("pr merge 66"), "unsettled PR never merged")
expect(review.merge_pr(dir, 66, { title = "PR 66" }) ~= stuck, "new record after a finished one")

local cancelled = review.merge_pr(dir, 73, { title = "PR 73" })
wait(function() return cancelled.state == "ci" end, "#73 waiting on CI")
review.cancel_merge(cancelled)
local finished = cancelled.finished
expect(cancelled.state == "failed" and cancelled.reason == "cancelled", "cancelled")
vim.wait(5 * review.settle_ms, function() return false end)
expect(not log():match("pr merge 73"), "cancelled PR never merged")
expect(cancelled.reason == "cancelled" and cancelled.finished == finished, "cancelled record unchanged")

local older = review.merge_pr(dir, 73, { title = "PR 73" })
wait(function() return older.state == "ci" end, "second #73 waiting on CI")
local newer = review.merge_pr(dir, 75, { title = "PR 75" })
merges.open(older)
expect(vim.api.nvim_get_current_line():match("#73"), "cursor starts on the older record")
wait(function() return newer.state == "asking" end, "#75 asking")
vim.wait(300)
expect(vim.api.nvim_get_current_line():match("#73"), "cursor stays on its record when the layout shifts")
vim.cmd("normal x")
expect(older.state == "failed" and older.reason == "cancelled", "x cancels the record under the cursor")
expect(newer.state == "asking", "the other record is untouched")
review.cancel_merge(newer)
vim.cmd("normal q")

local function footer_text()
  local chunks = vim.api.nvim_win_get_config(0).footer
  return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
end
local opened = {}
vim.ui.open = function(url) opened[#opened + 1] = url end

local red = review.merge_pr(dir, 77, { title = "PR 77" })
wait(function() return red.finished end, "#77 refused")
expect(red.state == "refused" and red.reason == "CI failed: lint · nothing started", "failed CI refused: " .. tostring(red.reason))
expect(red.note == "Fix the failing checks and push, then r retries.", "failed CI note")
expect(red.log_url == "https://ci.example/run/77", "failed CI log url")
expect(not log():match("pr merge 77"), "failed CI never merged")
merges.open(red)
expect(footer_text():find("l failed log", 1, true), "footer offers l failed log: " .. footer_text())
vim.cmd("normal l")
expect(vim.deep_equal(opened, { "https://ci.example/run/77" }), "l opens the failed log url")
vim.cmd("normal q")

local nolog = review.merge_pr(dir, 78, { title = "PR 78" })
wait(function() return nolog.finished end, "#78 refused")
expect(nolog.state == "refused" and nolog.log_url == nil, "failed check without url has no log_url")
merges.open(nolog)
expect(not footer_text():find("l failed log", 1, true), "footer hides l without a url: " .. footer_text())
vim.cmd("normal q")

local function flat(lines)
  local out = {}
  for _, segs in ipairs(lines) do
    out[#out + 1] = table.concat(vim.tbl_map(function(seg) return seg[1] end, segs))
  end
  return table.concat(out, "\n")
end
local view_pr = {
  number = 54, title = "PR 54", body = "", author = { login = "me" }, baseRefName = "master", headRefName = "feat/q",
  headRefOid = "a54", additions = 1, deletions = 0, changedFiles = 1, isDraft = false, state = "OPEN", mergeable = "MERGEABLE",
  reviewDecision = "APPROVED", updatedAt = "2026-01-01T00:00:00Z",
  statusCheckRollup = { { __typename = "CheckRun", name = "CI", status = "COMPLETED", conclusion = "SUCCESS" } },
  _behind = { count = 1, refs = { "#53" } },
}
local row = flat(review.views.pick_row(view_pr, "ready", 120))
expect(row:find("↓1 behind master (#53)", 1, true), "picker row shows the behind label: " .. row)
expect(not row:match("mergeable"), "behind PR is not shown as mergeable")
local preview = table.concat(review.views.pick_summary(view_pr, 140), "\n"):gsub("\27%[[%d;]*m", "")
expect(preview:find("master ──●──● #53 ← now", 1, true), "preview graph line: " .. preview)
expect(preview:find("└──● #54 ✓ CI ran here", 1, true), "preview graph fork line")
expect(preview:find("ran on master before #53", 1, true), "preview checks header")
expect(flat(review.views.detail_header(view_pr, 120)):find("↓1 behind master (#53)", 1, true), "detail header shows the behind label")

review.ci_timeout = 1
local first = review.merge_pr(dir, 63, { title = "PR 63" })
expect(review.merge_pr(dir, 63) == first, "running merge is deduplicated")
wait(function() return first.finished end, "#63 timed out")
expect(first.state == "failed" and first.reason:match("^CI still running"), "CI timeout")
expect(not log():match("pr merge 63"), "timed out PR never merged")

local function label(count, refs)
  local segs = review.ui.behind_segs({ baseRefName = "master", _behind = { count = count, refs = refs } })
  return table.concat(vim.tbl_map(function(seg) return seg[1] end, segs))
end
expect(label(1, { "#53" }) == "↓1 behind master (#53)", "label one")
expect(label(7, { "#53", "#52", "#51", "#50", "#49", "#48", "#47" }) == "↓7 behind master (#53, #52, +5)", "label many")
expect(label(2, { "#53" }) == "↓2 behind master (#53, +1)", "label partly named")

local copied = vim.tbl_filter(function(note) return not note:match("^Copied:") end, notes)
expect(#copied == 0, "no notifications from the merge flow: " .. table.concat(copied, " | "))

print("ok")
vim.cmd("qa!")
LUA

PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/state.json" FAKE_GH_LOG="$tmp/gh.log" \
  nvim --headless "+cd $tmp" "+luafile $tmp/test.lua" 2>&1
