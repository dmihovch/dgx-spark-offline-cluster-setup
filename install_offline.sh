#!/usr/bin/env bash
# Install a generated offline bundle on a compatible target system.
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR"

command -v docker >/dev/null 2>&1 || { echo "[offline] docker is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[offline] python3 is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[offline] tar is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "[offline] sha256sum is required" >&2; exit 1; }
[[ -f SHA256SUMS ]] || { echo "[offline] SHA256SUMS is missing" >&2; exit 1; }
[[ -f BUNDLE_INFO ]] || { echo "[offline] BUNDLE_INFO is missing" >&2; exit 1; }

echo "[offline] verifying checksums"
sha256sum -c SHA256SUMS

bundle_format=""
derived_image=""
target_platform=""
target_arch=""
target_python=""
requirements_file=""
requirements_sha256=""
image_archive=""
source_archive=""
model_cache_archive=""
ray_version=""
while IFS='=' read -r field value || [[ -n "$field$value" ]]; do
  case "$field" in
    bundle_format) bundle_format="$value" ;;
    derived_image) derived_image="$value" ;;
    target_platform) target_platform="$value" ;;
    target_arch) target_arch="$value" ;;
    target_python) target_python="$value" ;;
    requirements_file) requirements_file="$value" ;;
    requirements_sha256) requirements_sha256="$value" ;;
    image_archive) image_archive="$value" ;;
    source_archive) source_archive="$value" ;;
    model_cache_archive) model_cache_archive="$value" ;;
    ray_version) ray_version="$value" ;;
    base_image|base_image_id|built_utc) ;;
    *) echo "[offline] unknown BUNDLE_INFO field: $field" >&2; exit 1 ;;
  esac
done < BUNDLE_INFO

if [[ "$bundle_format" != 2 ]]; then
  echo "[offline] unsupported bundle format: $bundle_format" >&2
  exit 1
fi
for required_field in derived_image target_platform target_arch target_python requirements_file \
    requirements_sha256 image_archive source_archive model_cache_archive ray_version; do
  if [[ -z "${!required_field}" ]]; then
    echo "[offline] BUNDLE_INFO is missing $required_field" >&2
    exit 1
  fi
done

case "$target_platform" in
  linux/arm64)
    EXPECTED_ARCH=aarch64
    EXPECTED_IMAGE_ARCH=arm64
    ;;
  *) echo "[offline] unsupported bundle platform: $target_platform" >&2; exit 1 ;;
esac
if [[ "$target_arch" != "$EXPECTED_ARCH" ]]; then
  echo "[offline] target_arch does not match target_platform" >&2
  exit 1
fi
if [[ ! "$derived_image" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
  echo "[offline] invalid image name in BUNDLE_INFO" >&2
  exit 1
fi
if [[ ! "$ray_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[offline] invalid Ray version in BUNDLE_INFO" >&2
  exit 1
fi
if [[ ! "$target_python" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "[offline] invalid Python version in BUNDLE_INFO" >&2
  exit 1
fi
if [[ "$requirements_file" != requirements.lock ]]; then
  echo "[offline] unsupported requirements file in BUNDLE_INFO" >&2
  exit 1
fi
if [[ ! "$requirements_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "[offline] invalid requirements hash in BUNDLE_INFO" >&2
  exit 1
fi
if [[ "$image_archive" != vllm-ray-image.tar.zst && "$image_archive" != vllm-ray-image.tar.gz ]]; then
  echo "[offline] invalid image archive name in BUNDLE_INFO" >&2
  exit 1
fi
if [[ "$source_archive" != dgx-spark-benchmark-src.tar.gz ]]; then
  echo "[offline] invalid source archive name in BUNDLE_INFO" >&2
  exit 1
fi
if [[ "$model_cache_archive" != none && "$model_cache_archive" != model-cache.tar ]]; then
  echo "[offline] invalid model cache archive name in BUNDLE_INFO" >&2
  exit 1
fi

case "$(uname -m)" in
  aarch64|arm64) HOST_ARCH=aarch64 ;;
  x86_64|amd64) HOST_ARCH=x86_64 ;;
  *) echo "[offline] unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac
if [[ "$HOST_ARCH" != "$target_arch" ]]; then
  echo "[offline] bundle targets $target_arch, host is $HOST_ARCH" >&2
  exit 1
fi
HOST_PYTHON="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ "$HOST_PYTHON" != "$target_python" ]]; then
  echo "[offline] bundle targets Python $target_python, host Python is $HOST_PYTHON" >&2
  exit 1
fi

echo "[offline] loading $derived_image"
case "$image_archive" in
  *.zst)
    command -v zstd >/dev/null 2>&1 || { echo "[offline] zstd required for $image_archive" >&2; exit 1; }
    zstd -dc "$image_archive" | docker load
    ;;
  *.gz)
    command -v gzip >/dev/null 2>&1 || { echo "[offline] gzip is required for $image_archive" >&2; exit 1; }
    gzip -dc "$image_archive" | docker load
    ;;
esac
IMAGE_ARCH="$(docker image inspect --format '{{.Architecture}}' "$derived_image")"
if [[ "$IMAGE_ARCH" != "$EXPECTED_IMAGE_ARCH" ]]; then
  echo "[offline] loaded image architecture is $IMAGE_ARCH, expected $EXPECTED_IMAGE_ARCH" >&2
  exit 1
fi

SRC_DIR="${SRC_DIR:-$HOME/dgx-spark-llm-serving-benchmark}"
mkdir -p "$SRC_DIR"
SRC_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$SRC_DIR")"
if [[ "$SRC_DIR" == / ]]; then
  echo "[offline] SRC_DIR cannot be /" >&2
  exit 1
fi
echo "[offline] extracting source to $SRC_DIR"
tar --no-same-owner -xzf "$source_archive" -C "$SRC_DIR"
if [[ ! -f "$SRC_DIR/$requirements_file" ]]; then
  echo "[offline] $requirements_file is missing from the source archive" >&2
  exit 1
fi
SOURCE_REQUIREMENTS_SHA256="$(sha256sum "$SRC_DIR/$requirements_file" | awk '{print $1}')"
if [[ "$SOURCE_REQUIREMENTS_SHA256" != "$requirements_sha256" ]]; then
  echo "[offline] $requirements_file hash differs from BUNDLE_INFO" >&2
  exit 1
fi
[[ -d "$BUNDLE_DIR/wheels" ]] || { echo "[offline] wheels/ missing from the bundle" >&2; exit 1; }

if [[ "$model_cache_archive" != none ]]; then
  HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
  mkdir -p "$HF_CACHE"
  echo "[offline] extracting model cache to $HF_CACHE"
  tar --no-same-owner -xf "$model_cache_archive" -C "$HF_CACHE"
else
  echo "[offline] this bundle has no model weights"
fi

echo "[offline] creating client virtual environment"
python3 -m venv "$SRC_DIR/.venv"
PYTHONNOUSERSITE=1 PIP_NO_INDEX=1 "$SRC_DIR/.venv/bin/pip" install \
  --no-index --find-links "$BUNDLE_DIR/wheels" \
  -r "$SRC_DIR/$requirements_file"

echo "[offline] validating client environment"
PYTHONNOUSERSITE=1 "$SRC_DIR/.venv/bin/python" "$SRC_DIR/scripts/check_environment.py"

cat <<EOF

[offline] image loaded: $derived_image
[offline] source extracted: $SRC_DIR
[offline] client environment validated

Export on both nodes before running scripts:
  export VLLM_IMAGE="$derived_image"
  export RAY_VERSION="$ray_version"
  cd "$SRC_DIR"
  source scripts/connectx_env.sh
EOF
