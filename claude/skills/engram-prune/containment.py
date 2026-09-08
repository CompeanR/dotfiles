#!/usr/bin/env python3
"""Find session summaries whose fact is already CAPTURED by a typed row.

This is the high-yield duplicate class, and whole-document cosine cannot see
it: a short typed row (**What** / **Why** / **Learned**) and a long
session_summary from the same session state the same fact, but differ too much
in length and vocabulary to score as "similar".

Containment is the right metric — what fraction of the TYPED row's distinctive
words appear in the summary. Pairing is nearest-neighbour, so each summary is
proposed at most once (an earlier SQL version cross-joined and emitted 999 rows
for 1,181 observations, which is a cross-product, not a review list).

  python3 containment.py --project verseguard
  python3 containment.py --project verseguard --min-score 0.75 --ids-only
Output is a REVIEW list. Read both members before dropping. Keep the typed row.
"""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

DB = Path.home() / ".engram" / "engram.db"

STOP = set("""a an the and or but if then else of in on at to for from by with without
as is are was were be been being it its this that these those there here we you i they
he she them us our your their my me not no yes do does did done doing have has had can
could should would will shall may might must about into over under again further once
what which who whom whose when where why how all any both each few more most other some
such only own same so than too very s t just now also use used using via per etc""".split())

BOILER = re.compile(
    r"(?im)^\s*(#{1,4}\s*)?(\*\*)?(goal|instructions?|discoveries|accomplished|"
    r"next steps?|relevant files?|session|project|scope|what|why|where|learned)"
    r"(\*\*)?\s*:?\s*$")
WORD = re.compile(r"[a-z0-9_./-]{3,}")


def hours_apart(a_ts: str, b_ts: str) -> float:
    """Absolute hours between two SQLite timestamps; permissive on bad input."""
    from datetime import datetime
    fmt = "%Y-%m-%d %H:%M:%S"
    try:
        da = datetime.strptime((a_ts or "")[:19], fmt)
        db = datetime.strptime((b_ts or "")[:19], fmt)
    except ValueError:
        return 0.0
    return abs((da - db).total_seconds()) / 3600.0


def toks(text: str) -> set[str]:
    text = BOILER.sub(" ", text or "")
    text = re.sub(r"[*_`#|>]+", " ", text.lower())
    return {w for w in WORD.findall(text) if w not in STOP}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--min-score", type=float, default=0.70,
                   help="fraction of the typed row's distinctive words found in the summary")
    p.add_argument("--max-id-gap", type=int, default=4)
    p.add_argument("--max-hours", type=float, default=12.0)
    p.add_argument("--ids-only", action="store_true", help="print only the drop id list")
    p.add_argument("--db", default=str(DB))
    a = p.parse_args()

    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    rows = list(con.execute(
        "SELECT id, type, created_at, IFNULL(title,''), content FROM observations "
        "WHERE deleted_at IS NULL AND project = ? AND pinned = 0 "
        "AND IFNULL(topic_key,'') NOT LIKE 'follow-up/%' AND review_after IS NULL "
        "ORDER BY id", (a.project,)))

    summaries = [r for r in rows if r[1] == "session_summary"]
    typed = [r for r in rows if r[1] != "session_summary" and len(r[4] or "") > 200]
    tok = {r[0]: toks(r[4]) for r in rows}
    by_id = {r[0]: r for r in rows}

    hits = []
    for s in summaries:
        sid, stoks = s[0], tok[s[0]]
        if not stoks:
            continue
        best = None
        for t in typed:
            if abs(t[0] - sid) > a.max_id_gap:
                continue
            if hours_apart(t[2], s[2]) > a.max_hours:
                continue
            ttoks = tok[t[0]]
            if len(ttoks) < 12:
                continue
            score = len(ttoks & stoks) / len(ttoks)
            if best is None or score > best[0]:
                best = (score, t)
        if best and best[0] >= a.min_score:
            hits.append((best[0], best[1], s))

    hits.sort(key=lambda h: -h[0])
    drop_ids = [h[2][0] for h in hits]

    if a.ids_only:
        print(",".join(str(i) for i in drop_ids))
        return 0

    print(f"{len(summaries)} summaries, {len(typed)} typed rows, "
          f"threshold {a.min_score:.2f}\n")
    for score, t, s in hits:
        print(f"  score {score:.2f}  KEEP {t[0]} ({t[1]}) -> DROP {s[0]}")
        print(f"    typed  : {t[3][:70] or (t[4][:70] + '...')}")
        print(f"    summary: {(s[3] or s[4][:70])[:70]}")
    print(f"\n{len(drop_ids)} review candidates. Read both members before dropping.")
    print("drop ids: " + ",".join(str(i) for i in drop_ids))
    return 0


if __name__ == "__main__":
    sys.exit(main())
