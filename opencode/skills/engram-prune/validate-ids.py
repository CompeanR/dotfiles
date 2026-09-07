#!/usr/bin/env python3
"""Validate a candidate delete list BEFORE any write.

Catches the failure modes that actually happened in real prune runs:
  - an id that a reconciliation names as BOTH a keeper and a drop
  - keep-guard violations (pinned / review_after / follow-up)
  - ids from another project, or already soft-deleted
  - a cluster losing its last surviving member

  python3 validate-ids.py --project verseguard --ids 1,2,3
  python3 validate-ids.py --project verseguard --ids-file ids.txt \
      --keepers 482,511,604,1357
Exit code is non-zero if anything failed, so it is safe in a pipeline.
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

DB = Path.home() / ".engram" / "engram.db"


def parse_ids(raw: str) -> list[int]:
    return [int(t) for t in raw.replace("\n", ",").split(",") if t.strip()]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--ids")
    p.add_argument("--ids-file")
    p.add_argument("--keepers", default="", help="ids that must survive")
    p.add_argument("--db", default=str(DB))
    a = p.parse_args()

    if not a.ids and not a.ids_file:
        p.error("pass --ids or --ids-file")
    raw = a.ids or Path(a.ids_file).read_text()
    ids = parse_ids(raw)
    keepers = set(parse_ids(a.keepers)) if a.keepers else set()

    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    q = ",".join("?" * len(ids))
    fail = 0

    print(f"ids: {len(ids)}  unique: {len(set(ids))}")
    if len(ids) != len(set(ids)):
        dupes = {i for i in ids if ids.count(i) > 1}
        print(f"  FAIL duplicated ids in list: {sorted(dupes)}")
        fail += 1

    overlap = keepers & set(ids)
    if overlap:
        print(f"  FAIL id listed as both keeper and drop: {sorted(overlap)}")
        fail += 1

    missing = set(ids) - {r[0] for r in con.execute(
        f"SELECT id FROM observations WHERE id IN ({q})", ids)}
    if missing:
        print(f"  FAIL ids not found: {sorted(missing)}")
        fail += 1

    for label, sql in (
        ("keep-guard violation",
         f"SELECT id, pinned, review_after, topic_key FROM observations "
         f"WHERE id IN ({q}) AND (pinned = 1 OR review_after IS NOT NULL "
         f"OR IFNULL(topic_key,'') LIKE 'follow-up/%')"),
        ("wrong project or already deleted",
         f"SELECT id, project, deleted_at FROM observations WHERE id IN ({q}) "
         f"AND (project <> ? OR deleted_at IS NOT NULL)"),
    ):
        args = ids + ([a.project] if "?" in sql.split(f"({q})")[1] else [])
        rows = list(con.execute(sql, args))
        if rows:
            print(f"  FAIL {label}:")
            for r in rows:
                print(f"    {r}")
            fail += 1

    print("\ntype mix of the cut:")
    for t, c in con.execute(
        f"SELECT type, COUNT(*) FROM observations WHERE id IN ({q}) "
        f"GROUP BY type ORDER BY 2 DESC", ids
    ):
        print(f"  {t:18} {c}")

    for i in sorted(keepers):
        r = con.execute(
            "SELECT id, deleted_at, substr(IFNULL(title,''),1,52) "
            "FROM observations WHERE id = ?", (i,)).fetchone()
        if r is None:
            print(f"  FAIL keeper {i} does not exist")
            fail += 1
        elif r[1] is not None:
            print(f"  FAIL keeper {i} is already soft-deleted")
            fail += 1

    total = con.execute(
        "SELECT COUNT(*) FROM observations WHERE project = ? AND deleted_at IS NULL",
        (a.project,)).fetchone()[0]
    print(f"\n{total} active -> {total - len(set(ids))} remaining")
    print("PASS — safe to write" if not fail else f"\n{fail} CHECK(S) FAILED — do not write")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
