#!/usr/bin/env bash
# Assemble an offline bundle for the DGX Spark benchmark.
#
# Usage:
#   ./build_bundle.sh [--include-models] [OUTPUT_DIR]
#
# Environment overrides:
#   BENCHMARK_REPO  checkout to archive; auto-detected for an offline/ submodule
#   VLLM_IMAGE       base image from scripts/connectx_env.sh by default
#   RAY_VERSION      version pinned in scripts/ray-runtime-constraints.txt
#   TARGET_PYTHON    3.12 by default
#   DERIVED_IMAGE    dgx-spark-vllm-ray:$RAY_VERSION by default
#   ZSTD_LEVEL       3 by default
#   MODEL_CACHE_DIR  Hugging Face cache root for --include-models
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BENCHMARK_REPO:-}"
if [[ -n "$REPO_ROOT" ]]; then
  [[ -d "$REPO_ROOT" ]] || {
    echo "[offline] BENCHMARK_REPO is not a directory: $REPO_ROOT" >&2
    exit 2
  }
  REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
else
  CANDIDATE_REPO="$(cd "$HERE/.." && pwd)"
  if [[ -f "$CANDIDATE_REPO/requirements.lock" \
        && -f "$CANDIDATE_REPO/scripts/connectx_env.sh" ]]; then
    REPO_ROOT="$CANDIDATE_REPO"
  else
    echo "[offline] set BENCHMARK_REPO to a benchmark checkout" >&2
    exit 2
  fi
fi
export BENCHMARK_REPO="$REPO_ROOT"

INCLUDE_MODELS=0
OUTPUT_DIR=""
while (($#)); do
  case "$1" in
    --include-models)
      INCLUDE_MODELS=1
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--include-models] [OUTPUT_DIR]

Model weights are excluded unless --include-models is set. The Hugging Face
hub cache under MODEL_CACHE_DIR or HF_CACHE is added when that option is used.
EOF
      exit 0
      ;;
    --*)
      echo "[offline] unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$OUTPUT_DIR" ]]; then
        echo "[offline] only one OUTPUT_DIR may be specified" >&2
        exit 2
      fi
      OUTPUT_DIR="$1"
      ;;
  esac
  shift
done

source "$REPO_ROOT/scripts/connectx_env.sh"

TARGET_PLATFORM="${TARGET_PLATFORM:-linux/arm64}"
if [[ "$TARGET_PLATFORM" != "linux/arm64" ]]; then
  echo "[offline] only linux/arm64 targets are supported" >&2
  exit 2
fi
TARGET_PYTHON="${TARGET_PYTHON:-3.12}"
DERIVED_IMAGE="${DERIVED_IMAGE:-dgx-spark-vllm-ray:${RAY_VERSION}}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
REQUIREMENTS_FILE="$REPO_ROOT/requirements.lock"
RAY_CONSTRAINTS="$REPO_ROOT/scripts/ray-runtime-constraints.txt"
OUTPUT_DIR="${OUTPUT_DIR:-$HERE/offline-bundle}"

if [[ ! -f "$REQUIREMENTS_FILE" || ! -f "$RAY_CONSTRAINTS" ]]; then
  echo "[offline] requirements.lock and Ray constraints are required" >&2
  exit 1
fi
LOCKED_RAY_VERSION="$(awk -F '==' '$1 == "ray" { print $2; exit }' "$RAY_CONSTRAINTS")"
if [[ ! "$RAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$RAY_VERSION" != "$LOCKED_RAY_VERSION" ]]; then
  echo "[offline] RAY_VERSION=$RAY_VERSION does not match $RAY_CONSTRAINTS (ray==$LOCKED_RAY_VERSION)" >&2
  exit 1
fi
if [[ ! "$TARGET_PYTHON" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "[offline] TARGET_PYTHON must be a major.minor version, got: $TARGET_PYTHON" >&2
  exit 1
fi
if [[ ! "$DERIVED_IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
  echo "[offline] invalid DERIVED_IMAGE: $DERIVED_IMAGE" >&2
  exit 1
fi

TARGET_ARCH=aarch64
TARGET_IMAGE_ARCH=arm64
TARGET_PLATFORM_TAGS=(manylinux_2_28_aarch64 manylinux_2_17_aarch64 manylinux2014_aarch64 linux_aarch64)

command -v docker >/dev/null 2>&1 || { echo "[offline] docker is required" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "[offline] Docker Buildx is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[offline] python3 is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[offline] tar is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "[offline] sha256sum is required" >&2; exit 1; }
if ! command -v zstd >/dev/null 2>&1; then
  command -v gzip >/dev/null 2>&1 || { echo "[offline] gzip is required when zstd is unavailable" >&2; exit 1; }
fi

if (( INCLUDE_MODELS )); then
  MODEL_CACHE_DIR="${MODEL_CACHE_DIR:-${HF_CACHE:-}}"
  if [[ -z "$MODEL_CACHE_DIR" || ! -d "$MODEL_CACHE_DIR/hub" || -L "$MODEL_CACHE_DIR/hub" ]] \
      || ! find "$MODEL_CACHE_DIR/hub" -mindepth 1 -print -quit | grep -q .; then
    echo "[offline] --include-models requires a non-empty hub/ directory under MODEL_CACHE_DIR or HF_CACHE" >&2
    exit 1
  fi
fi

TARGET_ABI_LIST=("cp${TARGET_PYTHON/./}" abi3 none)

OUTPUT_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$OUTPUT_DIR")"
if [[ -e "$OUTPUT_DIR" ]]; then
  echo "[offline] output path already exists: $OUTPUT_DIR" >&2
  echo "[offline] choose a new output path to preserve existing files" >&2
  exit 1
fi
OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_PARENT"
STAGING_DIR="$(mktemp -d "$OUTPUT_PARENT/.offline-bundle.XXXXXX")"
trap 'if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then rm -rf -- "$STAGING_DIR"; fi' EXIT

echo "[offline] pulling $VLLM_IMAGE for $TARGET_PLATFORM"
docker pull --platform "$TARGET_PLATFORM" "$VLLM_IMAGE"
BASE_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$VLLM_IMAGE")"

BUILD_CONTEXT="$STAGING_DIR/docker-context"
mkdir -p "$BUILD_CONTEXT"
cp "$HERE/Dockerfile.ray" "$BUILD_CONTEXT/Dockerfile.ray"
cp "$RAY_CONSTRAINTS" "$BUILD_CONTEXT/ray-runtime-constraints.txt"

IMAGE_TAR="$STAGING_DIR/vllm-ray-image.tar"
echo "[offline] building $DERIVED_IMAGE for $TARGET_PLATFORM"
docker buildx build --platform "$TARGET_PLATFORM" \
  --build-arg "BASE_IMAGE=$VLLM_IMAGE" \
  --build-arg "RAY_VERSION=$RAY_VERSION" \
  --tag "$DERIVED_IMAGE" \
  --file "$BUILD_CONTEXT/Dockerfile.ray" \
  --output "type=docker,dest=$IMAGE_TAR" \
  "$BUILD_CONTEXT"
rm -rf -- "$BUILD_CONTEXT"

echo "[offline] loading image archive for architecture inspection"
docker load --input "$IMAGE_TAR"
IMAGE_ARCH="$(docker image inspect --format '{{.Architecture}}' "$DERIVED_IMAGE")"
if [[ "$IMAGE_ARCH" != "$TARGET_IMAGE_ARCH" ]]; then
  echo "[offline] built image architecture is $IMAGE_ARCH, expected $TARGET_IMAGE_ARCH" >&2
  exit 1
fi

echo "[offline] verifying Ray in the derived image"
if docker run --rm --platform "$TARGET_PLATFORM" --entrypoint python3 "$DERIVED_IMAGE" \
    -c 'import ray; print("ray", ray.__version__)'; then
  :
else
  echo "[offline] image execution is unavailable on this builder; verify Ray on the target system" >&2
fi

if command -v zstd >/dev/null 2>&1; then
  IMAGE_ARCHIVE=vllm-ray-image.tar.zst
  zstd -T0 "-$ZSTD_LEVEL" "$IMAGE_TAR" -o "$STAGING_DIR/$IMAGE_ARCHIVE"
else
  IMAGE_ARCHIVE=vllm-ray-image.tar.gz
  gzip -1 -c "$IMAGE_TAR" > "$STAGING_DIR/$IMAGE_ARCHIVE"
fi
rm -f "$IMAGE_TAR"

echo "[offline] downloading client wheels for $TARGET_ARCH Python $TARGET_PYTHON"
WHEEL_DIR="$STAGING_DIR/wheels"
mkdir -p "$WHEEL_DIR"
PIP_TARGET_ARGS=(--python-version "$TARGET_PYTHON" --implementation cp)
for TARGET_PLATFORM_TAG in "${TARGET_PLATFORM_TAGS[@]}"; do
  PIP_TARGET_ARGS+=(--platform "$TARGET_PLATFORM_TAG")
done
for TARGET_ABI in "${TARGET_ABI_LIST[@]}"; do
  PIP_TARGET_ARGS+=(--abi "$TARGET_ABI")
done
PIP_DISABLE_PIP_VERSION_CHECK=1 python3 -m pip download \
  --requirement "$REQUIREMENTS_FILE" \
  --dest "$WHEEL_DIR" \
  --only-binary=:all: \
  "${PIP_TARGET_ARGS[@]}"

echo "[offline] archiving source"
SOURCE_ARCHIVE=dgx-spark-benchmark-src.tar.gz
SOURCE_TAR_EXCLUDES=(
  --exclude-vcs
  --exclude='./.venv' --exclude='./venv' --exclude='./env'
  --exclude='./.aws' --exclude='./.ssh' --exclude='./.gnupg' --exclude='./.codex'
  --exclude='./.cache' --exclude='./__pycache__' --exclude='*.pyc'
  --exclude='./.env*' --exclude='*/.env*' --exclude='./.netrc' --exclude='./.pypirc'
  --exclude='./offline-bundle' --exclude='./offline-bundle-*'
  --exclude='./offline/offline-bundle-*' --exclude='./offline/.offline-bundle.*'
  --exclude='results*' --exclude='figs' --exclude='__pycache__'
)
case "$STAGING_DIR/" in
  "$REPO_ROOT/"*)
    STAGING_RELATIVE="${STAGING_DIR#"$REPO_ROOT"/}"
    SOURCE_TAR_EXCLUDES+=(--exclude="./$STAGING_RELATIVE")
    ;;
esac
tar -C "$REPO_ROOT" "${SOURCE_TAR_EXCLUDES[@]}" -czf "$STAGING_DIR/$SOURCE_ARCHIVE" .
cp "$HERE/install_offline.sh" "$STAGING_DIR/install_offline.sh"
chmod +x "$STAGING_DIR/install_offline.sh"

MODEL_CACHE_ARCHIVE=none
if (( INCLUDE_MODELS )); then
  MODEL_CACHE_ARCHIVE=model-cache.tar
  echo "[offline] archiving Hugging Face hub cache from $MODEL_CACHE_DIR"
  tar -C "$MODEL_CACHE_DIR" --exclude='hub/token' --exclude='hub/.locks' \
    -cf "$STAGING_DIR/$MODEL_CACHE_ARCHIVE" hub
else
  echo "[offline] model weights excluded; pass --include-models to add the Hugging Face hub cache"
fi

cat > "$STAGING_DIR/BUNDLE_INFO" <<EOF
bundle_format=2
derived_image=$DERIVED_IMAGE
base_image=$VLLM_IMAGE
base_image_id=$BASE_IMAGE_ID
ray_version=$RAY_VERSION
target_platform=$TARGET_PLATFORM
target_arch=$TARGET_ARCH
target_python=$TARGET_PYTHON
requirements_file=$(basename "$REQUIREMENTS_FILE")
requirements_sha256=$(sha256sum "$REQUIREMENTS_FILE" | awk '{print $1}')
image_archive=$IMAGE_ARCHIVE
source_archive=$SOURCE_ARCHIVE
model_cache_archive=$MODEL_CACHE_ARCHIVE
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

( cd "$STAGING_DIR" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )

mv "$STAGING_DIR" "$OUTPUT_DIR"
STAGING_DIR=""
echo "[offline] bundle written to $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
