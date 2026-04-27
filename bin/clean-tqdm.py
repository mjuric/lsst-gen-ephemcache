#!/usr/bin/env python3
"""
Clean cron/email logs that contain tqdm progress bars.

Adds:
- ISO-8601 UTC timestamp prefix to every emitted line.

Usage:
  some_command 2>&1 | python -u bin/clean_tqdm_stream.py
"""

from __future__ import annotations

import datetime as dt
import re
import sys
from typing import Optional

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

TQDM_ANY_RE = re.compile(
    r"""
    \b\d{1,3}%\|
    .*?\|
    \s*\d+/\d+
    \s*\[
    .*?
    (?:it/s|s/it)
    \]
    """,
    re.VERBOSE,
)

TQDM_HINT_RE = re.compile(
    r"\b\d{1,3}%\|.*\|\s*\d+/\d+\b|\[\d{2}:\d{2}<|\bit/s\]|\bs/it\]"
)

WRAP_CONT_RE = re.compile(
    r"""
    ^\s*(
        \[\d{2}:\d{2}<
      | \d{1,2}:\d{2},
      | (?:it/s|s/it)\]
      | \|\s*\d+/\d+
    )
    """,
    re.VERBOSE,
)


# ---------- timestamp helper ----------

def now_ts() -> str:
    """UTC ISO-8601 timestamp with Z."""
    return dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(line: str) -> None:
    """Emit a cleaned line with timestamp."""
    ts = now_ts()
    sys.stdout.write(f"[{ts}]  {line}\n")


# ---------- cleaning helpers ----------

def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def normalize_mojibake_blocks(s: str) -> str:
    # Replace common tqdm block mojibake with ASCII
    s = re.sub(r"â\x96[\x80-\xBF]", "#", s)
    s = re.sub(r"â..", "#", s)
    return s


def extract_last_tqdm(line: str) -> Optional[str]:
    matches = list(TQDM_ANY_RE.finditer(line))
    if not matches:
        return None
    return matches[-1].group(0).strip()


def looks_like_tqdm_start(line: str) -> bool:
    return bool(re.search(r"\b\d{1,3}%\|", line))


def looks_like_tqdm_incomplete(line: str) -> bool:
    return looks_like_tqdm_start(line) and extract_last_tqdm(line) is None


def looks_like_tqdm_continuation(line: str) -> bool:
    return bool(WRAP_CONT_RE.search(line) or TQDM_HINT_RE.search(line))


def clean_emit(line: str) -> None:
    line = strip_ansi(line)
    line = normalize_mojibake_blocks(line)
    line = line.rstrip("\n")

    if not line.strip():
        return

    last = extract_last_tqdm(line)
    if last is not None:
        emit(last)
        return

    emit(line)


# ---------- main stream processor ----------

def main() -> int:
    current = []
    pending_tqdm: Optional[str] = None

    def flush_line(raw_line: str) -> None:
        nonlocal pending_tqdm

        raw_line = raw_line.rstrip("\n")

        if pending_tqdm is not None:
            raw_line = pending_tqdm + raw_line.lstrip()
            pending_tqdm = None

        if looks_like_tqdm_incomplete(raw_line):
            pending_tqdm = raw_line
            return

        if (
            pending_tqdm is None
            and looks_like_tqdm_continuation(raw_line)
            and extract_last_tqdm(raw_line) is None
        ):
            return

        clean_emit(raw_line)

    data = sys.stdin.read()
    data = data.replace("\r\n", "\n")

    buf = []
    for ch in data:
        if ch == "\r":
            current.clear()
        elif ch == "\n":
            buf.append("".join(current) + "\n")
            current.clear()
        else:
            current.append(ch)

    if current:
        buf.append("".join(current) + "\n")

    for raw in buf:
        flush_line(raw)

    if pending_tqdm is not None:
        clean_emit(pending_tqdm)

    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
    