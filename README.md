# Offline DGX Spark setup

This repository builds a bundle for DGX Spark nodes without outbound network
access. The bundle contains a pinned vLLM image with Ray, the client wheelhouse
for the target platform, and the benchmark repository source. Model weights
are excluded unless `--include-models` is set.

Set `BENCHMARK_REPO` to the path of a `dgx-spark-llm-serving-benchmark`
checkout. The builder detects the parent checkout when this repository is
placed at its `offline/` path. Standalone clones require the environment
variable. The bundle builder archives `BENCHMARK_REPO`.

## Bundle contents

| File | Contents |
| --- | --- |
| `vllm-ray-image.tar.zst` or `vllm-ray-image.tar.gz` | Derived vLLM image with Ray installed |
| `wheels/` | Binary wheels for `requirements.lock` and the target platform |
| `dgx-spark-benchmark-src.tar.gz` | Repository source without Git history, generated results directories, or local secrets |
| `model-cache.tar` | Optional Hugging Face `hub/` cache |
| `install_offline.sh` | Installer for each target node |
| `BUNDLE_INFO` | Image, Ray, platform, Python, and requirements metadata |
| `SHA256SUMS` | Checksums for bundle files except `SHA256SUMS` itself |

The builder places `install_offline.sh` at the bundle root so it can be run
after transfer.

The derived image installs the Ray version pinned in
`scripts/ray-runtime-constraints.txt` and sets `PIP_NO_INDEX=1`. The
`scripts/start_ray.sh` pip command can use the installed packages and fails if a
package is missing because the image has no package-index access.

## Build

Run the builder on a machine with network access, Docker Buildx, Python 3 with
pip, `tar`, and `sha256sum`. It pulls the base image and downloads the locked
client wheels. `zstd` is optional; the builder uses gzip when zstd is absent.

Run from this repository root with `BENCHMARK_REPO` set:

```bash
BENCHMARK_REPO=/path/to/dgx-spark-llm-serving-benchmark \
  ./build_bundle.sh [--include-models] [OUTPUT_DIR]
```

The default output directory is `offline-bundle/` in this repository. The builder refuses
to overwrite an existing output path. The target is `linux/arm64` with Python
3.12.

For an x86_64 build host targeting DGX Spark, register arm64 emulation for the
Docker Buildx image build:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
docker run --rm --platform linux/arm64 alpine uname -m
```

The second command prints `aarch64` when the host can run arm64 containers.
The builder checks the saved image architecture. Ray import verification runs
when the build host can execute the target image.

### Include model weights

Model weights are excluded by default. To prepare a complete cache on a
networked build machine, set `HF_CACHE` and download the pinned snapshots:

```bash
BENCHMARK_REPO=/path/to/dgx-spark-llm-serving-benchmark \
  HF_CACHE=/media/external-drive/huggingface scripts/predownload.sh all
BENCHMARK_REPO=/path/to/dgx-spark-llm-serving-benchmark \
  HF_CACHE=/media/external-drive/huggingface CHECK_ONLY=1 scripts/predownload.sh all
```

The second command checks the snapshots against
`$BENCHMARK_REPO/configs/models.yaml`. The copied download helpers use the
benchmark checkout for its model matrix, cache settings, and Python environment.
To include the cache in a bundle, set MODEL_CACHE_DIR to the cache path and run:

```bash
BENCHMARK_REPO=/path/to/dgx-spark-llm-serving-benchmark \
  MODEL_CACHE_DIR=/media/external-drive/huggingface \
  ./build_bundle.sh --include-models /media/external-drive/offline-bundle
```

The cache root must contain a non-empty `hub/` directory. The builder excludes
`hub/token` and `hub/.locks`; it does not validate snapshot completeness.
To move the cache separately, omit `--include-models` and copy the cache to
each target node.

The builder supports `BENCHMARK_REPO`, `VLLM_IMAGE`, `RAY_VERSION`,
`TARGET_PYTHON`, `DERIVED_IMAGE`, `ZSTD_LEVEL`, and `MODEL_CACHE_DIR`
environment overrides. `RAY_VERSION` must match the version in
`scripts/ray-runtime-constraints.txt`.

## Stream model weights to an offline node

Use this workflow when a networked relay can connect to the offline Spark node
over SSH. Run `scripts/stream_model_cache.py` from this repository on the relay.
The node downloads the selected pinned snapshots into its own `HF_CACHE`. The
relay does not store model files.

### Prepare the Spark node

1. Install or clone `dgx-spark-llm-serving-benchmark` on the node. The default
   path is `$HOME/dgx-spark-llm-serving-benchmark`.
2. Configure the checkout's `.env`. Set `HF_CACHE` when the cache should use a
   custom path. Set `HF_TOKEN` for gated Hugging Face repositories. Set
   `VLLM_IMAGE` to an image tag available in the node's Docker daemon. For an
   image installed from this repository's bundle, use the `derived_image`
   value in `BUNDLE_INFO`.
3. Confirm that the SSH user can run Docker, `bash`, and `python3` on the node.
   The SSH server must permit remote TCP forwarding with a loopback listener on
   `127.0.0.1`.

The node does not need a clone of `offline-setup`. The relay copies
`predownload.sh` and its helper scripts to a temporary directory on the node and
runs them there. The downloader reads `.env` through the benchmark checkout's
`scripts/connectx_env.sh`. `HF_TOKEN` stays in the node's environment and is
used by the downloader running on that node. The configured image must already
be available locally because the offline node cannot pull it from a registry.

### Run the tunnel from the relay

Run the command from the root of this repository on a machine with Python 3,
`ssh`, `scp`, SSH access to the node, and outbound HTTPS access to Hugging Face:

```bash
cd /path/to/offline-setup
python3 scripts/stream_model_cache.py spark-head all
```

Replace `spark-head` with an SSH alias or `user@host` for the node. The target
must be reachable with both `ssh` and `scp` from the relay. The runner accepts
`single`, `tp2`, `pp2`, or `all`; the default is `single` when no model label is
provided.

To download one model entry, pass its `label` from the target checkout's
`configs/models.yaml`:

```bash
python3 scripts/stream_model_cache.py spark-head --model-label llama3.1-8b-fp8
```

When `--model-label` is used without a config, the runner searches all configs
and downloads only that label. An explicit config limits selection to models
configured for that serving config. The selected entry can also include a
separate tokenizer repository.

When the benchmark checkout uses a different path on the node, pass that
absolute target-node path:

```bash
python3 scripts/stream_model_cache.py spark-head all \
  --benchmark-repo /srv/dgx-spark-llm-serving-benchmark
```

Keep the relay command running until it exits. The runner opens an SSH reverse
forward bound to `127.0.0.1` on the node and starts the snapshot downloader
there. The node sends HTTPS CONNECT requests through the reverse forward to a
loopback-only proxy on the relay. TLS remains encrypted between the node and
Hugging Face. Model files are written directly to the node's `HF_CACHE`.

The relay needs outbound port 443 access to Hugging Face hosts under
`huggingface.co` and `hf.co`. Hugging Face lists download endpoints in its
[proxy and firewall guidance](https://huggingface.co/docs/hub/datasets-downloading#downloading-behind-a-proxy-or-firewall).
The node needs enough free space in `HF_CACHE` for the selected snapshots. The
downloader checks available space before downloading and checks snapshot
completeness before it exits. It attempts to remove the temporary helper
directory after the command exits.

To repeat the local cache check on the node, run:

```bash
cd "$HOME/dgx-spark-llm-serving-benchmark"
source scripts/connectx_env.sh
CHECK_ONLY=1 scripts/predownload.sh all
```

`CHECK_ONLY=1` checks pinned snapshots in the local cache and does not contact
Hugging Face. Use `build_bundle.sh --include-models` when the model cache must
be packaged for transfer with the offline bundle.

## Transfer and install

Copy the complete bundle directory to each target node:

```bash
BUNDLE_DIR=/absolute/path/to/offline-bundle
rsync -avP --partial "$BUNDLE_DIR/" /media/external-drive/offline-bundle/
```

Each target node requires Docker, Python 3.12, `tar`, `sha256sum`, and the
compression tool named by the image archive (`zstd` or `gzip`). Run the
installer from the copied bundle directory:

```bash
./install_offline.sh
```

The installer checks checksums, host architecture, and Python major and minor
version. It loads the image, extracts the source to
`$HOME/dgx-spark-llm-serving-benchmark`, creates `.venv`, installs the
wheelhouse without an index, and runs `scripts/check_environment.py`. Set
`SRC_DIR` to choose another source directory. Set `HF_CACHE` when installing
a bundle with model weights; the default is `$HOME/.cache/huggingface`.

The source archive omits `.env` files and Git history. Configure each node's
benchmark checkout `.env` with its network addresses and interface settings
before starting Ray. Follow `$BENCHMARK_REPO/docs/cluster-setup.md` and
`$BENCHMARK_REPO/docs/rdma-readiness.md` for hardware configuration.

## Run Ray and all-reduce

On both nodes, set the image and Ray version from the copied bundle metadata.
Set `BUNDLE_DIR` to the bundle directory on each node:

```bash
BUNDLE_DIR=/media/external-drive/offline-bundle
export VLLM_IMAGE="$(awk -F= '$1 == "derived_image" {print $2}' "$BUNDLE_DIR/BUNDLE_INFO")"
export RAY_VERSION="$(awk -F= '$1 == "ray_version" {print $2}' "$BUNDLE_DIR/BUNDLE_INFO")"
cd "$HOME/dgx-spark-llm-serving-benchmark"
source scripts/connectx_env.sh
```

Start the Ray head on one node and the worker on the other:

```bash
scripts/start_ray.sh head
scripts/start_ray.sh worker
```

After both nodes report `Active`, run this on the head:

```bash
scripts/ray_allreduce_bench.sh
```

The all-reduce output is written to
`results/allreduce_ray_<fingerprint>_<timestamp>.csv`.

## Run model benchmarks from the local cache

Model-serving runs require complete pinned snapshots in the Hugging Face cache.
When the bundle includes `model-cache.tar`, the installer extracts it into
`HF_CACHE`. Otherwise copy a complete `hub/` cache to each node. For a custom
cache location, set the same `HF_CACHE` in each node's `.env`.

Activate the installed client environment and export the image settings in each
shell:

```bash
cd "$HOME/dgx-spark-llm-serving-benchmark"
source .venv/bin/activate
export PYTHON="$PWD/.venv/bin/python"
BUNDLE_DIR=/media/external-drive/offline-bundle
export VLLM_IMAGE="$(awk -F= '$1 == "derived_image" {print $2}' "$BUNDLE_DIR/BUNDLE_INFO")"
export RAY_VERSION="$(awk -F= '$1 == "ray_version" {print $2}' "$BUNDLE_DIR/BUNDLE_INFO")"
source scripts/connectx_env.sh
```

On each node, validate that its cache contains every pinned snapshot required
by the run. This command is local-only and does not contact Hugging Face:

```bash
CHECK_ONLY=1 scripts/predownload.sh all
```

`launch_server.sh` defaults to `HF_HUB_OFFLINE=1`. Direct
`run_models.sh single` defaults to online mode and acquires snapshots before
launch. Set `RUN_JOB_CACHE_READY=1` to skip that acquisition step and
`HF_HUB_OFFLINE=1` to keep serving local-only. Run a single-node sweep on the
head:

```bash
RUN_JOB_CACHE_READY=1 HF_HUB_OFFLINE=1 \
  OUT_DIR=results/offline-single scripts/run_models.sh single
```

For dual-node runs, validate the required cache on both nodes. `RUN_JOB_CACHE_READY=1`
also skips the runner's worker-cache mirror, so each node must have the complete
snapshot cache before launch. Start Ray on both nodes, then run this command on
the head:

```bash
RUN_JOB_CACHE_READY=1 HF_HUB_OFFLINE=1 \
  OUT_DIR=results/offline-tp2 scripts/run_models.sh tp2
```

Use `pp2` in place of `tp2` for pipeline parallel. A missing or incomplete
snapshot stops at the local cache preflight before server launch. The
`run_job.sh` campaign wrapper requires a clean committed Git checkout. The
bundle source archive omits Git history, so use `run_models.sh` for model runs
from an installed bundle.

## Offline troubleshooting

- `weight_gb` or `kv_cache_gb` is blank because model configuration or Hub
  metadata is unavailable: confirm that the required snapshot is in the local
  cache and that gated repositories have valid credentials on the networked
  build host.
- `client tokenizer preflight failed`: confirm the pinned tokenizer snapshot is
  complete and that the model entry's `trust_remote_code` setting is correct.
  Run `CHECK_ONLY=1 scripts/predownload.sh <config>` to validate the local
  snapshots for one serving configuration.
