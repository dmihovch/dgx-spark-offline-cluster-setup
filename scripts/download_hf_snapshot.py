#!/usr/bin/env python3
"""Download one pinned Hugging Face snapshot into the configured Hub cache."""
from __future__ import annotations

import os
import sys

from failure_diagnostics import redact_diagnostic


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        print(
            "usage: download_hf_snapshot.py REPOSITORY REVISION WORKERS",
            file=sys.stderr,
        )
        return 2
    repository, revision, worker_count = arguments
    try:
        workers = int(worker_count)
    except ValueError:
        print("[cache] WORKERS must be a positive integer", file=sys.stderr)
        return 2
    if workers < 1:
        print("[cache] WORKERS must be a positive integer", file=sys.stderr)
        return 2

    os.umask(0o002)
    from huggingface_hub import snapshot_download

    try:
        path = snapshot_download(
            repository,
            revision=revision or None,
            max_workers=workers,
            ignore_patterns=["original/*", "metal/*", "*.pth", "*.gguf"],
        )
    except Exception as exc:
        detail = redact_diagnostic(str(exc), (os.environ.get("HF_TOKEN"),))
        cache_path = os.environ.get("HF_HUB_CACHE", "<unset>")
        print(
            f"[acquire] FAILED {repository}@{revision or 'main'}: "
            f"{type(exc).__name__}: {detail}; cache={cache_path}; "
            "check repository access, revision, network, and cache permissions",
            file=sys.stderr,
        )
        return 1
    print(f"[acquire] complete {repository}@{revision or 'main'} -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
