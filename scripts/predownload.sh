#!/usr/bin/env bash
# Acquire pinned model snapshots in the head node's Hugging Face cache just
# before the selected run, so `vllm serve` does not spend its readiness budget
# pulling weights. The campaign uses this same step for single- and dual-node
# model groups, then mirrors the snapshot to the worker when needed.
#
# Why: scripts/run_models.sh gives each server READY_TIMEOUT seconds (default
# 1800) to come up, then tears it down. On a cold cache the largest checkpoints
# spend most of that window just downloading (llama3.3-70b-fp8 took 803s and
# nemotron3-super-120b-a12b-nvfp4 took 1103s to download alone), so they were
# killed mid-load before ever serving. Warming the cache first removes that race.
#
#   scripts/predownload.sh single      # every model whose configs include single (default)
#   scripts/predownload.sh tp2
#   scripts/predownload.sh pp2
#   scripts/predownload.sh all         # every model in models.yaml, across all configs
#
# Downloads run inside the same VLLM_IMAGE and into the same HF_CACHE mount that
# launch_server.sh uses, so the serving path sees the same local files. Each
# unique repo is fetched once (a model shared across configs, or reused by an
# on-the-fly-quant entry like llama3.3-70b-fp8, is not downloaded twice). Gated
# repos (meta-llama) use HF_TOKEN from .env. Redundant PyTorch/Metal/GGUF copies
# (meta-llama's original/*.pth, gpt-oss's original/ and metal/) are skipped;
# vLLM loads the safetensors. The disk check sizes exactly those files with
# scripts/hf_snapshot_size.py, net of blobs already in the cache.
#
# scripts/run_job.sh calls this once per model group; direct run_models.sh calls
# it for the selected model before launch. The campaign always purges canary
# groups and applies PURGE_WEIGHTS to measurement cleanup.
#
# Downloads are pinned to the revisions in models.yaml and are idempotent and
# resumable. CHECK_ONLY=1 performs the same local-only completeness validation
# that run_models.sh uses before it commits any GPU time.
#
# Env: MODELS_YAML, HF_CACHE, HF_TOKEN, VLLM_IMAGE (all via connectx_env.sh),
#      PYTHON (host interpreter for the YAML parse, default python3),
#      DRY_RUN=1 (list the repos it would fetch, then exit without downloading),
#      CHECK_ONLY=1 (validate pinned snapshots locally; never use the network),
#      MODEL_LABELS (optional space-separated label allowlist),
#      DOWNLOAD_DNS (Docker DNS for downloads, defaults to CONTAINER_DNS;
#                    empty uses Docker's host-derived resolver),
#      DOWNLOAD_WORKERS (parallel HF files, default 1 for reliable campus DNS),
#      PREDOWNLOAD_MIN_FREE_GB (free-space reserve, default 10 GiB),
#      DOWNLOAD_PROXY (loopback HTTP proxy for tunneled HTTPS downloads).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_REPO_ROOT="$(cd "$HERE/.." && pwd)"
BENCHMARK_REPO="${BENCHMARK_REPO:-}"
if [[ -z "$BENCHMARK_REPO" ]]; then
  CANDIDATE_REPO="$(cd "$OFFLINE_REPO_ROOT/.." && pwd)"
  if [[ -f "$CANDIDATE_REPO/configs/models.yaml" \
        && -f "$CANDIDATE_REPO/scripts/connectx_env.sh" ]]; then
    BENCHMARK_REPO="$CANDIDATE_REPO"
  else
    echo "[predownload] set BENCHMARK_REPO to a benchmark checkout" >&2
    exit 2
  fi
fi
[[ -f "$BENCHMARK_REPO/scripts/connectx_env.sh" ]] || {
  echo "[predownload] benchmark setup script is missing under $BENCHMARK_REPO" >&2
  exit 2
}
BENCHMARK_REPO="$(cd "$BENCHMARK_REPO" && pwd)"
source "$BENCHMARK_REPO/scripts/connectx_env.sh"
acquire_resource_lock || exit 1
wait_for_resources_idle auto || exit 1

CONFIG="${1:-single}"
case "$CONFIG" in single|tp2|pp2|all) ;; *)
  echo "usage: predownload.sh [single|tp2|pp2|all]" >&2; exit 1 ;;
esac

MODELS_YAML="${MODELS_YAML:-$BENCHMARK_REPO/configs/models.yaml}"
if [[ -z "${PYTHON:-}" && -x "$BENCHMARK_REPO/.venv/bin/python" ]]; then
  PYTHON="$BENCHMARK_REPO/.venv/bin/python"
else
  PYTHON="${PYTHON:-python3}"
fi
CHECK_ONLY="${CHECK_ONLY:-0}"
MODEL_LABELS="${MODEL_LABELS:-}"
DOWNLOAD_DNS="${DOWNLOAD_DNS-$CONTAINER_DNS}"
DOWNLOAD_WORKERS="${DOWNLOAD_WORKERS:-1}"
if [[ ! -v DOWNLOAD_PROXY ]]; then DOWNLOAD_PROXY=""; fi
download_network_args=()
download_proxy_args=()
if [[ -n "$DOWNLOAD_PROXY" ]]; then
  if [[ ! "$DOWNLOAD_PROXY" =~ ^http://127\.0\.0\.1:[1-9][0-9]{0,4}$ ]]; then
    echo "[predownload] DOWNLOAD_PROXY must use http://127.0.0.1:<port>" >&2
    exit 2
  fi
  proxy_port="${DOWNLOAD_PROXY##*:}"
  if (( proxy_port > 65535 )); then
    echo "[predownload] DOWNLOAD_PROXY port must be between 1 and 65535" >&2
    exit 2
  fi
  export HTTPS_PROXY="$DOWNLOAD_PROXY" https_proxy="$DOWNLOAD_PROXY"
  export NO_PROXY="" no_proxy=""
  # The SSH remote-forward listener is on host loopback.
  download_network_args=( --network host )
  download_proxy_args=(
    -e "HTTPS_PROXY=$DOWNLOAD_PROXY" -e "https_proxy=$DOWNLOAD_PROXY"
    -e NO_PROXY= -e no_proxy=
  )
fi

# Which serving configs to cover. "all" unions every config so a shared repo is
# still fetched once.
CONFIGS=("$CONFIG")
if [[ "$CONFIG" == "all" ]]; then CONFIGS=(single tp2 pp2); fi

# Collect unique repo/revision pairs (model names, plus any explicit tokenizer
# repos) in first-seen order. The kind is retained so the local check can require
# model weights while allowing a tokenizer-only repository to contain no weights.
declare -A SEEN
SPECS=()
add_spec() {
  local repo="$1" revision="$2" kind="$3" key="$1|$2"
  if [[ -z "${SEEN[$key]:-}" ]]; then
    SEEN[$key]="$kind"
    SPECS+=("$repo|$revision|$kind")
  elif [[ "$kind" == "model" ]]; then
    SEEN[$key]="model"
  fi
}
for cfg in "${CONFIGS[@]}"; do
  # exits 1 when no model requests a config; tolerate that under "all", but
  # not a malformed matrix (exit 2), which would otherwise fetch nothing.
  rc=0
  entries="$("$PYTHON" "$HERE/models_for_config.py" "$MODELS_YAML" "$cfg")" || rc=$?
  if (( rc > 1 )); then
    echo "[predownload] cannot read $MODELS_YAML for $cfg" >&2
    exit 1
  fi
  [[ -z "$entries" ]] && continue
  while IFS='|' read -r label name revision maxlen gpu_util quant tok tokrev trust _max_num_seqs; do
    [[ -z "$name" ]] && continue
    if [[ -n "$MODEL_LABELS" ]]; then
      selected=0
      for wanted in $MODEL_LABELS; do
        [[ "$label" == "$wanted" ]] && selected=1
      done
      [[ "$selected" == "0" ]] && continue
    fi
    if [[ -z "$revision" ]]; then
      echo "[predownload] $label has no pinned revision in $MODELS_YAML" >&2
      exit 1
    fi
    add_spec "$name" "$revision" model
    if [[ -n "$tok" ]]; then
      if [[ -z "$tokrev" && "$tok" == "$name" ]]; then tokrev="$revision"; fi
      if [[ -z "$tokrev" ]]; then
        echo "[predownload] $label uses tokenizer $tok without tokenizer_revision" >&2
        exit 1
      fi
      add_spec "$tok" "$tokrev" tokenizer
    fi
  done <<<"$entries"
done

if [[ "${#SPECS[@]}" -eq 0 ]]; then
  echo "[predownload] no models request config '$CONFIG' in $MODELS_YAML" >&2
  exit 1
fi

echo "[predownload] ${#SPECS[@]} pinned snapshot(s) for '$CONFIG' -> $HF_CACHE"
printf '  %s\n' "${SPECS[@]}"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[predownload] DRY_RUN=1, nothing downloaded"
  exit 0
fi

if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "[predownload] note: HF_TOKEN is unset; gated repos (e.g. meta-llama) will fail." >&2
  echo "[predownload]       set HF_TOKEN in .env if any gated model does not download." >&2
fi

mkdir -p "$HF_CACHE"
if [[ "${CACHE_ACCESS_VERIFIED:-0}" != "1" ]]; then
  check_hf_cache_access
  check_hf_cache_access_in_image
fi

# Reserve exactly what the pinned snapshots still need. The Hub's per-file
# sizes for each pinned revision, minus blobs already complete in this cache,
# are compared with free space plus a 10 GiB OS buffer
# (PREDOWNLOAD_MIN_FREE_GB overrides). A Hub query failure
# exits before the first download. Skipped in CHECK_ONLY mode.
check_disk_space() {
  local spec repo revision kind size_report needed_bytes
  local -a size_specs=()
  for spec in "${SPECS[@]}"; do
    IFS='|' read -r repo revision kind <<<"$spec"
    size_specs+=("$repo@$revision")
  done
  if ! size_report="$("$PYTHON" "$HERE/hf_snapshot_size.py" "$HF_CACHE" "${size_specs[@]}")"; then
    echo "[predownload] FAILED: cannot size the pinned snapshots from the HF API" >&2
    return 1
  fi
  printf '%s\n' "$size_report" | grep -v '^total_needed_bytes=' || true
  needed_bytes="$(printf '%s\n' "$size_report" | sed -n 's/^total_needed_bytes=//p')"
  [[ "$needed_bytes" =~ ^[0-9]+$ ]] || {
    echo "[predownload] FAILED: unparseable size report" >&2; return 1; }

  local available_kb need_kb buffer_kb min_free_gb
  available_kb=$(df --output=avail "$HF_CACHE" 2>/dev/null | tail -n1 | awk '{print $1}')
  if [[ -z "$available_kb" || "$available_kb" -le 0 ]]; then
    echo "[predownload] cannot determine free space on $HF_CACHE" >&2
    return 1
  fi
  need_kb=$((needed_bytes / 1024))
  min_free_gb="${PREDOWNLOAD_MIN_FREE_GB:-10}"
  if [[ ! "$min_free_gb" =~ ^[0-9]{1,6}$ ]]; then
    echo "[predownload] PREDOWNLOAD_MIN_FREE_GB must be a non-negative integer" >&2
    return 2
  fi
  min_free_gb=$((10#$min_free_gb))
  buffer_kb=$((min_free_gb * 1024 * 1024))
  echo "[predownload] $HF_CACHE: $((available_kb / 1024 / 1024)) GiB free, need $((need_kb / 1024 / 1024)) GiB + $((buffer_kb / 1024 / 1024)) GiB OS buffer"
  if [[ "$available_kb" -lt $((need_kb + buffer_kb)) ]]; then
    echo "[predownload] FAILED: need $(((need_kb + buffer_kb) / 1024 / 1024)) GiB, have $((available_kb / 1024 / 1024)) GiB." >&2
    echo "[predownload] Set HF_CACHE to a path with more space, purge finished models (scripts/purge_model_cache.sh), or override with PREDOWNLOAD_MIN_FREE_GB=0." >&2
    return 1
  fi
}
if [[ "$CHECK_ONLY" != "1" ]]; then
  check_disk_space || exit 1
fi

run_env=( -e HF_HOME=/hf-cache -e HF_HUB_CACHE=/hf-cache/hub
  -e HF_MODULES_CACHE=/hf-cache/modules
  -e HF_HUB_DISABLE_SHARED_BLOBS="$HF_HUB_DISABLE_SHARED_BLOBS"
  -e HF_HUB_DISABLE_PROGRESS_BARS=1 )
dns_args=()
if [[ -z "$DOWNLOAD_PROXY" && -n "$DOWNLOAD_DNS" ]]; then
  dns_args=( --dns "$DOWNLOAD_DNS" )
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  check_args=()
  for spec in "${SPECS[@]}"; do
    IFS='|' read -r repo revision kind <<<"$spec"
    # Upgrade a tokenizer duplicate to the stronger model check.
    kind="${SEEN["$repo|$revision"]}"
    check_args+=("$repo" "$revision" "$kind")
  done
  echo "[predownload] CHECK_ONLY=1: validating local pinned snapshots"
  # Cache operations only need Python; do not run the serving image entrypoint
  # that may initialize GPU and driver support.
  docker run --rm --user "$HF_CACHE_UID:$HF_CACHE_GID" \
    --entrypoint python3 \
    -e HOME=/tmp -v "$HF_CACHE":/hf-cache \
    -v "$HERE/cache_access_probe.py:/tmp/cache_access_probe.py:ro" \
    "${run_env[@]}" "$VLLM_IMAGE" \
    -c 'import json, sys
from pathlib import Path
from huggingface_hub import snapshot_download

errors = []
args = sys.argv[1:]
for i in range(0, len(args), 3):
    repo, revision, kind = args[i:i + 3]
    try:
        path = Path(snapshot_download(
            repo, revision=revision or None, local_files_only=True,
            ignore_patterns=["original/*", "metal/*", "*.pth", "*.gguf"],
        ))
        if revision and path.name != revision:
            raise RuntimeError(f"resolved snapshot is {path.name}, expected {revision}")
        broken = [str(p.relative_to(path)) for p in path.rglob("*")
                  if p.is_symlink() and not p.exists()]
        repo_root = path.parents[1]
        partial = list((repo_root / "blobs").glob("*.incomplete"))
        missing = []
        if kind == "model":
            indexes = list(path.glob("*.safetensors.index.json"))
            indexes += list(path.glob("*.bin.index.json"))
            for index in indexes:
                weight_map = json.loads(index.read_text()).get("weight_map", {})
                missing.extend(name for name in set(weight_map.values())
                               if not (path / name).is_file())
            if not indexes and not (list(path.glob("*.safetensors"))
                                    or list(path.glob("*.bin"))):
                missing.append("no model weight files found")
        if broken or partial or missing:
            detail = []
            if broken: detail.append("broken links: " + ", ".join(broken[:5]))
            if partial: detail.append(f"{len(partial)} incomplete blob(s)")
            if missing: detail.append("missing weights: " + ", ".join(missing[:5]))
            raise RuntimeError("; ".join(detail))
        print(f"[predownload] OK {repo}@{revision or 'main'} -> {path}")
    except Exception as exc:
        errors.append(f"{repo}@{revision or 'main'}: {type(exc).__name__}: {exc}")
if errors:
    print("[predownload] CACHE PREFLIGHT FAILED:", file=sys.stderr)
    for error in errors:
        print("  " + error, file=sys.stderr)
    raise SystemExit(1)' "${check_args[@]}"
  echo "[predownload] all pinned snapshots for '$CONFIG' are complete"
  exit 0
fi

# Only the network download needs credentials. Forward the variable by name so
# its value is not embedded in the docker CLI argv (and therefore visible in
# host process listings); the local-only cache preflight above receives none.
if [[ -n "${HF_TOKEN:-}" ]]; then run_env+=( -e HF_TOKEN ); fi

FAILURES=0
for spec in "${SPECS[@]}"; do
  IFS='|' read -r repo revision kind <<<"$spec"
  echo "[acquire] start $repo@$revision"
  if docker run --rm "${download_network_args[@]}" \
       --user "$HF_CACHE_UID:$HF_CACHE_GID" \
       --entrypoint python3 \
       -e HOME=/tmp -v "$HF_CACHE":/hf-cache \
       -v "$HERE/download_hf_snapshot.py:/tmp/download_hf_snapshot.py:ro" \
       -v "$HERE/failure_diagnostics.py:/tmp/failure_diagnostics.py:ro" \
       "${dns_args[@]}" "${download_proxy_args[@]}" "${run_env[@]}" \
       "$VLLM_IMAGE" -u /tmp/download_hf_snapshot.py \
       "$repo" "$revision" "$DOWNLOAD_WORKERS"; then
    :
  else
    echo "[predownload] FAILED $repo (gated repo without HF_TOKEN, or bad name?)" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if (( FAILURES > 0 )); then
  echo "[predownload] $FAILURES repo(s) failed; see output above" >&2
  exit 1
fi
CACHE_ACCESS_VERIFIED=1 CHECK_ONLY=1 MODEL_LABELS="$MODEL_LABELS" \
  "$0" "$CONFIG"
echo "[predownload] all pinned snapshots for '$CONFIG' cached under $HF_CACHE"
echo "[predownload] now run: scripts/run_models.sh $([[ "$CONFIG" == all ]] && echo single || echo "$CONFIG")"
