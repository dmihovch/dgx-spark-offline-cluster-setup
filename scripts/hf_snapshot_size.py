#!/usr/bin/env python3
"""Exact bytes still needed to download pinned Hugging Face snapshots.

predownload.sh used to read the Hub's ``safetensors.total`` as a byte count.
That field is a *parameter* count, so a BF16 checkpoint needed twice what was
reserved, and the ``usedStorage`` fallback counted every revision and every
duplicate weight copy. This helper asks the Hub for the pinned revision's file
list with sizes, applies the same ignore patterns as the download, and
subtracts blobs that are already complete in the local cache, so a resumed
download only reserves what it still has to fetch.

    hf_snapshot_size.py HF_CACHE REPO@REVISION [REPO@REVISION ...]

Prints one line per repo and a final ``total_needed_bytes=<n>`` line. Exits 1
when any Hub query fails, before anything is downloaded. HF_TOKEN, when set,
is sent for gated or private repos.
"""
from __future__ import annotations

import fnmatch
import json
import os
from pathlib import Path
import re
import sys
import urllib.request

from failure_diagnostics import redact_diagnostic

# Keep in sync with the snapshot_download() call in predownload.sh. original/
# and metal/ hold duplicate PyTorch/Metal copies of the same weights (vLLM
# serves the top-level safetensors).
IGNORE_PATTERNS = ("original/*", "metal/*", "*.pth", "*.gguf")


def snapshot_files(repo: str, revision: str, token: str | None) -> list[dict]:
    url = f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"
    headers = {"User-Agent": "dgx-spark-benchmark/1.0"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.loads(response.read().decode())
    if payload.get("sha") != revision:
        raise ValueError(f"Hub resolved {repo}@{revision} to {payload.get('sha')!r}")
    files = []
    for sibling in payload.get("siblings") or []:
        name = sibling.get("rfilename") or ""
        if any(fnmatch.fnmatch(name, pattern) for pattern in IGNORE_PATTERNS):
            continue
        size = sibling.get("size")
        if not isinstance(size, int) or size < 0:
            raise ValueError(f"no size for {repo}:{name}")
        lfs = sibling.get("lfs") or {}
        # The cache names a blob by its etag: the LFS sha256 for LFS files and
        # the git blob id otherwise.
        files.append({"name": name, "size": size,
                      "blob": lfs.get("sha256") or sibling.get("blobId") or ""})
    if not files:
        raise ValueError(f"{repo}@{revision} lists no downloadable files")
    return files


def cached_bytes(hf_cache: Path, repo: str, files: list[dict]) -> int:
    blobs = hf_cache / "hub" / ("models--" + repo.replace("/", "--")) / "blobs"
    present = 0
    for item in files:
        path = blobs / item["blob"] if item["blob"] else None
        try:
            if path is not None and path.stat().st_size == item["size"]:
                present += item["size"]
        except OSError:
            pass
    return present


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: hf_snapshot_size.py HF_CACHE REPO@REVISION [...]", file=sys.stderr)
        return 2
    hf_cache = Path(argv[0])
    token = os.environ.get("HF_TOKEN") or None
    total = 0
    seen = set()
    for spec in argv[1:]:
        repo, _, revision = spec.partition("@")
        if (repo, revision) in seen:
            continue
        if not repo or not re.fullmatch(r"[0-9a-f]{40}", revision):
            print(f"[size] invalid spec {spec!r}; expected REPO@<40-hex>", file=sys.stderr)
            return 2
        seen.add((repo, revision))
        try:
            files = snapshot_files(repo, revision, token)
        except Exception as exc:  # network, HTTP, or malformed metadata
            detail = redact_diagnostic(str(exc), (token,))
            print(
                f"[size] FAILED {repo}@{revision}: {type(exc).__name__}: "
                f"{detail}; cache={hf_cache / 'hub'}; check repository access, "
                "revision, network, and cache permissions",
                file=sys.stderr,
            )
            return 1
        full = sum(item["size"] for item in files)
        have = cached_bytes(hf_cache, repo, files)
        need = max(0, full - have)
        total += need
        print(f"[size] {repo}@{revision[:12]}: snapshot {full / 1e9:.1f} GB, "
              f"cached {have / 1e9:.1f} GB, to fetch {need / 1e9:.1f} GB")
    print(f"total_needed_bytes={total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
