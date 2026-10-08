#!/usr/bin/env python3
"""Apply titles to blank-titled observations. Guarded and idempotent.

Input is a TSV of `id<TAB>title`, one per line (# comments allowed).
An UPDATE only fires when the row is still blank-titled, still active
and in the target project, so re-running is safe and a row that was
retitled by hand is never clobbered.

  python3 retitle.py --project verseguard --map titles.tsv            # dry run
  python3 retitle.py --project verseguard --map titles.tsv \
      --write --backup ~/.engram/engram.db.backup-YYYYmmdd-HHMMSS
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

DB = Path.home() / ".engram" / "engram.db"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--map", required=True, help="TSV: id<TAB>title")
    p.add_argument("--write", action="store_true")
    p.add_argument("--backup", help="existing backup file; required with --write")
    p.add_argument("--allow-generic", action="store_true",
                   help="also retitle rows whose title is generic "
                        "(e.g. 'Session summary'), not just blank ones")
    p.add_argument("--db", default=str(DB))
    a = p.parse_args()

    # A row is retitleable when its title carries no retrieval signal.
    title_guard = (
        "(TRIM(IFNULL(title,'')) = '' OR title LIKE 'Session summary%' "
        "OR title LIKE 'sdd/%')"
        if a.allow_generic else "TRIM(IFNULL(title,'')) = ''"
    )

    db = Path(a.db).expanduser()
    if not db.is_file():
        print(f"missing db: {db}", file=sys.stderr)
        return 2
    if a.write:
        if not a.backup:
            print("--write requires --backup pointing at the copy from Step 0", file=sys.stderr)
            return 2
        backup = Path(a.backup).expanduser()
        if not backup.is_file() or backup.stat().st_size < 1:
            print(f"backup missing or empty: {backup}", file=sys.stderr)
            return 2
        if backup.resolve() == db.resolve():
            print("backup path must not be the live DB", file=sys.stderr)
            return 2

    pairs: list[tuple[int, str]] = []
    for ln in Path(a.map).read_text().splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        sid, _, title = ln.partition("\t")
        title = title.strip()
        if not title:
            print(f"skip (no title): {ln}", file=sys.stderr)
            continue
        if len(title) > 60:
            print(f"skip (title >60 chars): {sid}", file=sys.stderr)
            continue
        pairs.append((int(sid), title))

    con = sqlite3.connect(str(db) if a.write else f"file:{db}?mode=ro", uri=not a.write)
    changed = 0
    for oid, title in pairs:
        cur = con.execute(
            "SELECT substr(REPLACE(content, char(10), ' '), 1, 90) FROM observations "
            f"WHERE id = ? AND deleted_at IS NULL AND project = ? AND {title_guard}",
            (oid, a.project),
        ).fetchone()
        if cur is None:
            print(f"  skip {oid:>5}  (title not retitleable / not active / wrong project)")
            continue
        print(f"  {oid:>5}  {title}")
        print(f"         └─ {cur[0]}")
        if a.write:
            con.execute(
                "UPDATE observations SET title = ?, updated_at = datetime('now') "
                f"WHERE id = ? AND deleted_at IS NULL AND project = ? AND {title_guard}",
                (title, oid, a.project),
            )
            changed += 1
    if a.write:
        con.commit()
        left = con.execute(
            "SELECT COUNT(*) FROM observations WHERE deleted_at IS NULL "
            f"AND project = ? AND {title_guard}", (a.project,)).fetchone()[0]
        print(f"\nretitled: {changed};  untitled/generic remaining: {left}")
    else:
        print(f"\nDRY RUN — {len(pairs)} mapped, nothing written. Add --write --backup to apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
