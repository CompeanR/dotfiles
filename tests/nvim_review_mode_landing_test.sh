#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cd "$tmp"
git init -q
git config user.email "review-mode-test@example.com"
git config user.name "Review Mode Test"
for i in $(seq 1 40); do
  printf 'local line_%02d = %d\n' "$i" "$i"
done > main.lua
git add main.lua
git commit -qm "initial"
sed -i '29s/.*/local line_29 = "changed"/' main.lua

nvim --headless "+cd $tmp" "+edit main.lua" \
  "+lua local actions = assert(package.loaded.git_hunk_nav_actions); local land = actions.land; actions.land = function(direction, callback) land(direction, function(...) _G.review_land_done = true; if callback then callback(...) end end) end" \
  "+ReviewStart HEAD" \
  "+lua local ok = vim.wait(8000, function() local gs = package.loaded.gitsigns; local h = gs and gs.get_hunks(0); return _G.review_land_done and h and #h > 0 and vim.api.nvim_win_get_cursor(0)[1] == h[1].added.start end, 100); if ok then print('ok - landed on first hunk') else local gs = package.loaded.gitsigns; local h = gs and gs.get_hunks(0) or {}; print(string.format('not ok - completed=%s hunks=%d first=%s cursor=%d', tostring(_G.review_land_done), #h, tostring(h[1] and h[1].added.start), vim.api.nvim_win_get_cursor(0)[1])); vim.cmd('cquit') end" \
  "+ReviewStop" "+qa!"

printf '\nok - review mode landing regression\n'
