#!/usr/bin/env python3
"""Run an Engram prune SQL asset against ~/.engram/engram.db.

Read-only by default. Writes require --write and an existing --backup.

  python3 run.py assets/audit.sql --project verseguard
  python3 run.py assets/noise-candidates.sql --project verseguard
  python3 run.py assets/verify.sql --project verseguard
  python3 run.py --soft-delete-ids 12,34 --project verseguard --write --backup ~/.engram/engram.db.backup-...
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

WRITE_HEAD = re.compile(
    r"^\s*(UPDATE|DELETE|INSERT|REPLACE|VACUUM|DROP|ALTER|CREATE|ATTACH)\b",
    re.I,
)
KEEP_GUARD = """
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
""".strip()


def iter_statements(sql: str):
    buf: list[str] = []
    i = 0
    n = len(sql)
    in_single = False
    while i < n:
        if not in_single and sql.startswith("--", i):
            while i < n and sql[i] != "\n":
                i += 1
            continue
        c = sql[i]
        if c == "'":
            buf.append(c)
            i += 1
            if in_single:
                if i < n and sql[i] == "'":
                    buf.append(sql[i])
                    i += 1
                else:
                    in_single = False
            else:
                in_single = True
            continue
        if c == ";" and not in_single:
            stmt = "".join(buf).strip()
            buf = []
            if stmt:
                yield stmt
            i += 1
            continue
        buf.append(c)
        i += 1
    stmt = "".join(buf).strip()
    if stmt:
        yield stmt


def substitute(sql: str, args: argparse.Namespace) -> str:
    partial = args.partial or args.project
    return (
        sql.replace("{PROJECT}", args.project)
        .replace("{PROJECT_PARTIAL}", partial)
        .replace("{OLD_KEY}", args.old_key or "")
        .replace("{NEW_KEY}", args.new_key or "")
    )


def print_rows(cur: sqlite3.Cursor) -> None:
    rows = cur.fetchall()
    names = [d[0] for d in cur.description] if cur.description else []
    if not names:
        print(f"  rows-changed: {cur.rowcount}")
        return
    print("  " + " | ".join(names))
    if not rows:
        print("  (0 rows)")
        return
    for row in rows:
        print("  " + " | ".join("" if v is None else str(v) for v in row))
    print(f"  ({len(rows)} rows)")


def connect(db: Path, write: bool) -> sqlite3.Connection:
    if write:
        con = sqlite3.connect(db)
    else:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def run_script(con: sqlite3.Connection, sql: str, write: bool) -> None:
    for stmt in iter_statements(sql):
        is_write = bool(WRITE_HEAD.match(stmt))
        preview = re.sub(r"\s+", " ", stmt)[:120]
        if is_write and not write:
            print(f"SKIP write (pass --write): {preview}")
            continue
        print(f"SQL: {preview}")
        cur = con.execute(stmt)
        print_rows(cur)
        print()
    if write:
        con.commit()


def soft_delete(con: sqlite3.Connection, project: str, ids: list[int], write: bool) -> None:
    placeholders = ",".join("?" * len(ids))
    preview_sql = f"""
SELECT id, type, topic_key, substr(title, 1, 80) AS title
FROM observations
WHERE deleted_at IS NULL AND project = ? AND id IN ({placeholders})
{KEEP_GUARD}
"""
    blocked_sql = f"""
SELECT id, type, topic_key, substr(title, 1, 80) AS title,
  CASE
    WHEN pinned = 1 THEN 'pinned'
    WHEN IFNULL(topic_key, '') LIKE 'follow-up/%' THEN 'follow-up'
    WHEN review_after IS NOT NULL THEN 'review_after'
    ELSE 'other-guard'
  END AS blocked_reason
FROM observations
WHERE deleted_at IS NULL AND project = ? AND id IN ({placeholders})
AND NOT (
  pinned = 0
  AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
  AND review_after IS NULL
)
"""
    args = [project, *ids]
    print("SQL: preview IDs that keep-guards would allow")
    print_rows(con.execute(preview_sql, args))
    print()
    print("SQL: IDs blocked by keep-guards (will not be deleted)")
    print_rows(con.execute(blocked_sql, args))
    print()
    if not write:
        print("Dry-run only. Re-run with --write --backup to soft-delete the allowed IDs.")
        return
    cur = con.execute(
        f"""
UPDATE observations SET deleted_at = datetime('now'), updated_at = datetime('now')
WHERE deleted_at IS NULL AND project = ? AND id IN ({placeholders})
{KEEP_GUARD}
""",
        args,
    )
    con.commit()
    print(f"soft-deleted: {cur.rowcount}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("sql_file", nargs="?", help="SQL asset to run (skipped with --soft-delete-ids)")
    p.add_argument("--project", required=True, help="Engram project key (lowercase)")
    p.add_argument("--partial", help="Override {PROJECT_PARTIAL} for sibling-key search")
    p.add_argument("--old-key", help="For migrate.sql {OLD_KEY}")
    p.add_argument("--new-key", help="For migrate.sql {NEW_KEY} (must be lowercase)")
    p.add_argument("--db", default=str(Path.home() / ".engram/engram.db"))
    p.add_argument("--write", action="store_true", help="Allow UPDATE/DELETE (default: read-only)")
    p.add_argument("--backup", help="Existing backup path; required with --write")
    p.add_argument(
        "--soft-delete-ids",
        help="Comma-separated observation IDs to soft-delete (keep-guards applied)",
    )
    args = p.parse_args()

    db = Path(args.db).expanduser()
    if not db.is_file():
        print(f"missing db: {db}", file=sys.stderr)
        return 1
    if args.write:
        if not args.backup:
            print("--write requires --backup pointing at the copy from Step 0", file=sys.stderr)
            return 1
        backup = Path(args.backup).expanduser()
        if not backup.is_file() or backup.stat().st_size < 1:
            print(f"backup missing or empty: {backup}", file=sys.stderr)
            return 1
        if backup.resolve() == db.resolve():
            print("backup path must not be the live DB", file=sys.stderr)
            return 1

    ids: list[int] = []
    if args.soft_delete_ids:
        try:
            ids = [int(x.strip()) for x in args.soft_delete_ids.split(",") if x.strip()]
        except ValueError:
            print("invalid --soft-delete-ids", file=sys.stderr)
            return 1
        if not ids:
            print("empty --soft-delete-ids", file=sys.stderr)
            return 1
    elif not args.sql_file:
        p.error("sql_file is required unless --soft-delete-ids is set")

    con = connect(db, args.write)
    try:
        if ids:
            soft_delete(con, args.project, ids, args.write)
            return 0
        path = Path(args.sql_file)
        if not path.is_file():
            print(f"missing sql: {path}", file=sys.stderr)
            return 1
        sql_text = path.read_text()
        sql = substitute(sql_text, args)
        if ("{OLD_KEY}" in sql_text or "{NEW_KEY}" in sql_text) and (
            not args.old_key or not args.new_key
        ):
            print("migrate.sql needs --old-key and --new-key", file=sys.stderr)
            return 1
        if args.new_key and args.new_key != args.new_key.lower():
            print("--new-key must be lowercase (engram sync exports 0 rows otherwise)", file=sys.stderr)
            return 1
        run_script(con, sql, args.write)
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
