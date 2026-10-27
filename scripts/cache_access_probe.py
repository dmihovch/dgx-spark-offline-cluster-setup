#!/usr/bin/env python3
"""Check create, read, and delete access to the selected Hub cache."""
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys
import tempfile


def probe_cache(cache_path: str) -> None:
    """Exercise file operations inside the selected repository cache."""
    root = Path(cache_path).expanduser()
    try:
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".cache-access-probe-", dir=root) as directory:
            probe_path = Path(directory) / "probe"
            with probe_path.open("wb") as probe:
                probe.write(b"cache access probe\n")
                probe.flush()
                os.fsync(probe.fileno())
            if probe_path.read_bytes() != b"cache access probe\n":
                raise OSError("probe contents changed after write")
            probe_path.unlink()
    except OSError as exc:
        message = (
            f"{type(exc).__name__} during cache create/read/delete at {root}; "
            f"effective UID:GID {os.geteuid()}:{os.getegid()}"
        )
        try:
            cache_stat = root.stat()
        except OSError:
            pass
        else:
            message += (
                f"; directory owner UID:GID {cache_stat.st_uid}:{cache_stat.st_gid}"
                f", mode {stat.S_IMODE(cache_stat.st_mode):04o}"
            )
        message += (
            ". Set HF_CACHE to a directory writable by this user with enough "
            "free space, then rerun; this does not require sudo."
        )
        raise OSError(message) from exc
    print(
        f"[cache] create/read/delete OK: {root} "
        f"(UID:GID {os.geteuid()}:{os.getegid()})"
    )


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        print("usage: cache_access_probe.py HF_HUB_CACHE", file=sys.stderr)
        return 2
    try:
        probe_cache(arguments[0])
    except OSError as exc:
        print(f"[cache] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
