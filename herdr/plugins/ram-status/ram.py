#!/usr/bin/env python3
"""One-line host RAM/swap (CLI only; not wired into Herdr UI)."""

from pathlib import Path

MEMINFO = Path("/proc/meminfo")


def parse_meminfo(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        parts = rest.strip().split()
        if not parts:
            continue
        out[key] = int(parts[0])
    return out


def fmt_gib(kib: int) -> str:
    g = kib / 1024 / 1024
    return f"{g:.0f}" if abs(g - round(g)) < 0.05 else f"{g:.1f}"


def fmt_pair(used_kib: int, total_kib: int) -> str:
    return f"{fmt_gib(used_kib)}/{fmt_gib(total_kib)}G"


def format_status(text: str) -> str:
    info = parse_meminfo(text)
    total = info["MemTotal"]
    available = info.get("MemAvailable", info.get("MemFree", 0))
    used = max(total - available, 0)
    pct = round(used * 100 / total) if total else 0
    prefix = "! " if pct >= 90 else ""
    line = f"{prefix}{fmt_pair(used, total)} {pct}%"
    swap_total = info.get("SwapTotal", 0)
    swap_used = max(swap_total - info.get("SwapFree", 0), 0) if swap_total else 0
    if swap_used and fmt_gib(swap_used) != "0":
        line += f"  swap {fmt_pair(swap_used, swap_total)}"
    return line


def main() -> None:
    print(format_status(MEMINFO.read_text()))


if __name__ == "__main__":
    main()
