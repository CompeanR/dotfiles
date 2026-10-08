#!/usr/bin/env bash
set -eu

gate=0
[ "${1:-}" = "--gate" ] && gate=1 && shift
base=${1:-origin/{{DEFAULT_BRANCH}}}
head=${2:-HEAD}
for ref in "$base" "$head"; do
    git rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "unknown revision: $ref" >&2; exit 2; }
done
range="$base...$head"

attr_flag=
if [ "$gate" = 1 ] && git cat-file -e "$base:.gitattributes" 2>/dev/null; then
    attr_flag="--source=$(git rev-parse "$base")"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git diff -M --name-status -z "$range" | tr '\0' '\n' | awk -F'\t' '
    st == "" { st = $0; need = (st ~ /^[RC]/) ? 2 : 1; n = 0; next }
    ++n == need { print substr(st, 1, 1) "\t" $0; st = "" }' >"$tmp/status"

git diff -M --numstat -z "$range" | tr '\0' '\n' | awk -F'\t' '
    renamed { if (++k == 2) { print a "\t" d "\t" $0; renamed = 0 } next }
    NF >= 3 && $3 == "" { a = $1; d = $2; renamed = 1; k = 0; next }
    { print $1 "\t" $2 "\t" $3 }' >"$tmp/numstat"

cut -f2 "$tmp/status" | git check-attr $attr_flag --stdin linguist-generated review | awk '
    { v = $0; sub(/^.*: /, "", v); h = $0; sub(/: [^:]*$/, "", h); a = h; sub(/^.*: /, "", a); p = h; sub(/: [^:]*$/, "", p) }
    a == "linguist-generated" && v == "set" { print "gen\t" p }
    a == "review" && v == "content" { print "content\t" p }' >"$tmp/attrs"

awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { cls[$2] = $1; next }
    FILENAME == ARGV[2] { st[$2] = $1; next }
    {
        p = $3; s = st[p]; c = cls[p]
        if (s == "R" && $1 + $2 == 0) c = "moved"
        else if (c == "") {
            if (p ~ /{{TEST_PATTERN}}/) c = "test"
            else c = "code"
        }
        print c, s, $1 + 0, $2 + 0, p
    }' "$tmp/attrs" "$tmp/status" "$tmp/numstat" >"$tmp/files"

git log --reverse --format='%h %s' "$base..$head" >"$tmp/commits"

deps=$(git diff --name-only "$range" -- {{DEPS_PATHSPEC}} | tr '\n' ' ')

awk -F'\t' -v gate="$gate" -v deps="$deps" -v commits="$tmp/commits" '
function fmt(n,  s, r) { s = (n + 0) ""; r = ""; while (length(s) > 3) { r = "," substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) } return s r }
function istest(p) { return p ~ /{{TEST_PATTERN}}/ }
function top(p,  a, n) { n = split(p, a, "/"); if (n == 1) return "(root)"; if (a[1] ~ /^({{GROUP_DIRS}})$/ && n > 2) return a[1] "/" a[2]; return a[1] }
function cell(d, g) { return F[d, g] ? "+" fmt(A[d, g]) "/-" fmt(D[d, g]) : "-" }
function warn(m) { print (gate ? "::warning::" : "Warning: ") m }
function list(s, k,  n, a, i, r) { n = split(s, a, " "); for (i = 1; i <= n && i <= k; i++) r = r (i > 1 ? ", " : "") a[i]; return r (n > k ? ", ..." : "") }
{
    c = $1; s = $2; n = $3 + $4; p = $5
    nf[c]++; ln[c] += n; total++
    d = top(p)
    if (!(d in seen)) { seen[d] = 1; dirs[++nd] = d }
    g = (c == "code" || c == "test") ? "hand" : c
    if (g == "hand" || g == "content" || g == "gen") { A[d, g] += $3; D[d, g] += $4; F[d, g]++; T[d] += n; G[d] = 1 }
    if (g == "hand") { hn[++nh] = n; hp[nh] = p; hk[nh] = n + (c == "code" ? 1000000 : 0) }
    if (s == "D" && g == "hand") { deleted[++ndel] = p; dellines += n }
    if (istest(p) && s == "D") deltest++
    if (istest(p) && s == "M") modtest++
    if (p ~ /^(\.gitattributes|\.github\/|\.githooks\/|scripts\/|CLAUDE\.md|AGENTS\.md|{{CONFIG_FILES}}|Makefile)/) guard = guard " " p
}
END {
    if (!total) { print "no changes"; exit 0 }
    hand = ln["code"] + ln["test"]; hfiles = nf["code"] + nf["test"]
    size = fmt(hand) " hand lines in " hfiles " files (" fmt(ln["code"]) " code, " fmt(ln["test"]) " tests)"
    if (nf["content"]) size = size " · content " fmt(ln["content"]) " in " nf["content"]
    if (nf["gen"]) size = size " · generated " fmt(ln["gen"]) " in " nf["gen"]
    size = size " · " total " files"
    if (nf["moved"]) size = size " · moved " nf["moved"]
    if (ndel) size = size " · of which deleted " ndel " files (" fmt(dellines) " lines)"
    print size
    print ""
    print "Commits, in reading order:"
    while ((getline line < commits) > 0) if (++nc <= 30) print "  " nc ". " line
    print ""
    for (i = 1; i < nd; i++) for (j = i + 1; j <= nd; j++) if (T[dirs[j]] > T[dirs[i]]) { x = dirs[i]; dirs[i] = dirs[j]; dirs[j] = x }
    print "| Directory | Hand +/- | Content +/- | Generated +/- |"
    print "|---|---|---|---|"
    for (i = 1; i <= nd; i++) if (G[dirs[i]]) print "| " dirs[i] " | " cell(dirs[i], "hand") " | " cell(dirs[i], "content") " | " cell(dirs[i], "gen") " |"
    print ""
    mr = ""
    if (deps != "") mr = mr "; dependencies (" list(deps, 3) ")"
    if (deltest) mr = mr "; deleted tests (" deltest ")"
    if (modtest) mr = mr "; changed tests (" modtest ")"
    if (guard != "") mr = mr "; guardrails (" list(guard, 3) ")"
    print "Must read: " (mr == "" ? "nothing flagged" : substr(mr, 3))
    print "Moved: " (nf["moved"] + 0) " files (verify with git diff -M --stat)"
    for (i = 1; i <= nh && i <= 15; i++) {
        for (j = i + 1; j <= nh; j++) if (hk[j] > hk[i]) { x = hk[i]; hk[i] = hk[j]; hk[j] = x; x = hn[i]; hn[i] = hn[j]; hn[j] = x; x = hp[i]; hp[i] = hp[j]; hp[j] = x }
        if (i == 1) print "\nLargest hand files:"
        print "  " fmt(hn[i]) "  " hp[i]
    }
    for (i = 1; i <= ndel && i <= 10; i++) print (i == 1 ? "\nDeleted files (they count as hand lines):\n" : "") "  " deleted[i]
    if (ndel > 10) print "  and " (ndel - 10) " more"

    print ""
    if (hand > 1500) verdict = "over the 1,500-line limit"
    else if (hand > 500) verdict = "over the 500-line target; the PR body must say why it cannot split"
    else verdict = "within the 500-line target"
    print "Budget: " fmt(hand) " hand lines, " verdict "."
    if (hand > 500 && hand <= 1500) warn("PR scope: " fmt(hand) " hand lines is over the 500-line target; the PR body must say why it cannot split.")
    if (hfiles > 50) warn("PR scope: " hfiles " hand files is over 50; consider splitting.")

    if (gate && hand > 1500) {
        print "::error::PR scope: " fmt(hand) " hand lines is over 1,500. Split this PR, or add the scope-exception label with a rationale in the PR body."
        exit 1
    }
}' "$tmp/files"
