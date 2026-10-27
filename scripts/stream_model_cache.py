#!/usr/bin/env python3
"""Download pinned Hugging Face snapshots to an SSH-reachable offline node."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import threading

from https_connect_proxy import (
    HfConnectProxyHandler,
    ThreadingConnectProxyServer,
)

HELPER_NAMES: tuple[str, ...] = (
    "predownload.sh",
    "models_for_config.py",
    "hf_snapshot_size.py",
    "cache_access_probe.py",
    "download_hf_snapshot.py",
    "failure_diagnostics.py",
)
REMOTE_DIRECTORY_PATTERN: re.Pattern[str] = re.compile(
    r"/tmp/offline-setup\.[A-Za-z0-9]+"
)
REMOTE_PORT_COMMAND: str = (
    "python3 -c 'import socket; "
    "connection = socket.socket(); "
    "connection.bind((\"127.0.0.1\", 0)); "
    "print(connection.getsockname()[1]); "
    "connection.close()'"
)
SSH_STARTUP_WAIT_SECONDS: float = 0.5
SSH_TERMINATE_WAIT_SECONDS: float = 5


@dataclass(frozen=True)
class Arguments:
    ssh_target: str
    config: str
    benchmark_repo: str | None


def parse_arguments(argv: list[str]) -> Arguments:
    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        description=(
            "Use an SSH reverse tunnel to download pinned snapshots into "
            "the target node's Hugging Face cache."
        )
    )
    parser.add_argument("ssh_target", help="SSH alias or user@host for the node")
    parser.add_argument(
        "config",
        nargs="?",
        choices=("single", "tp2", "pp2", "all"),
        default="single",
    )
    parser.add_argument(
        "--benchmark-repo",
        help=(
            "absolute path to the benchmark checkout on the target node; "
            "defaults to $HOME/dgx-spark-llm-serving-benchmark"
        ),
    )
    parsed: argparse.Namespace = parser.parse_args(argv)
    if parsed.ssh_target.startswith("-") or any(
        character.isspace() for character in parsed.ssh_target
    ):
        parser.error("ssh_target must be an SSH alias or user@host without spaces")
    if parsed.benchmark_repo is not None and not PurePosixPath(
        parsed.benchmark_repo
    ).is_absolute():
        parser.error("--benchmark-repo must be an absolute target-node path")
    return Arguments(
        ssh_target=parsed.ssh_target,
        config=parsed.config,
        benchmark_repo=parsed.benchmark_repo,
    )


def run_ssh_capture(
    ssh_target: str, remote_command: str, purpose: str
) -> str:
    completed: subprocess.CompletedProcess[str] = subprocess.run(
        ["ssh", "-T", ssh_target, remote_command],
        check=False,
        stdout=subprocess.PIPE,
        text=True,
        timeout=30,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"SSH command failed while {purpose}")
    return completed.stdout.strip()


def create_remote_helper_directory(ssh_target: str) -> str:
    remote_directory: str = run_ssh_capture(
        ssh_target,
        "mktemp -d -- /tmp/offline-setup.XXXXXXXX",
        "creating the temporary helper directory",
    )
    if REMOTE_DIRECTORY_PATTERN.fullmatch(remote_directory) is None:
        raise RuntimeError("SSH returned an invalid temporary directory path")
    return remote_directory


def choose_remote_forward_port(ssh_target: str) -> int:
    port_text: str = run_ssh_capture(
        ssh_target, REMOTE_PORT_COMMAND, "choosing the SSH forward port"
    )
    try:
        remote_port: int = int(port_text)
    except ValueError as error:
        raise RuntimeError("SSH returned an invalid forward port") from error
    if not 1 <= remote_port <= 65535:
        raise RuntimeError("SSH returned a forward port outside the valid range")
    return remote_port


def copy_download_helpers(
    ssh_target: str, remote_directory: str, script_directory: Path
) -> None:
    helper_paths: list[Path] = [
        script_directory / helper_name for helper_name in HELPER_NAMES
    ]
    missing_helpers: list[str] = [
        str(helper_path) for helper_path in helper_paths if not helper_path.is_file()
    ]
    if missing_helpers:
        raise RuntimeError(
            "required download helpers are missing: " + ", ".join(missing_helpers)
        )
    subprocess.run(
        [
            "scp",
            "-q",
            "-p",
            *(str(helper_path) for helper_path in helper_paths),
            f"{ssh_target}:{remote_directory}/",
        ],
        check=True,
    )


def start_ssh_reverse_forward(
    ssh_target: str, remote_port: int, local_port: int
) -> subprocess.Popen[bytes]:
    command: list[str] = [
        "ssh",
        "-T",
        "-N",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=3",
        "-R",
        f"127.0.0.1:{remote_port}:127.0.0.1:{local_port}",
        ssh_target,
    ]
    tunnel_process: subprocess.Popen[bytes] = subprocess.Popen(command)
    try:
        tunnel_process.wait(timeout=SSH_STARTUP_WAIT_SECONDS)
    except subprocess.TimeoutExpired:
        return tunnel_process
    raise RuntimeError("SSH reverse-forward process exited during startup")


def stop_ssh_reverse_forward(
    tunnel_process: subprocess.Popen[bytes] | None,
) -> None:
    if tunnel_process is None:
        return
    if tunnel_process.poll() is None:
        tunnel_process.terminate()
    try:
        tunnel_process.wait(timeout=SSH_TERMINATE_WAIT_SECONDS)
    except subprocess.TimeoutExpired:
        tunnel_process.kill()
        tunnel_process.wait()


def remove_remote_helper_directory(
    ssh_target: str, remote_directory: str
) -> None:
    try:
        completed: subprocess.CompletedProcess[bytes] = subprocess.run(
            [
                "ssh",
                "-T",
                ssh_target,
                f"rm -rf -- {shlex.quote(remote_directory)}",
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(
            f"[tunnel] could not remove remote helper directory "
            f"{remote_directory}: {error}",
            file=sys.stderr,
        )
        return
    if completed.returncode != 0:
        print(
            f"[tunnel] could not remove remote helper directory {remote_directory}",
            file=sys.stderr,
        )


def run_remote_download(
    ssh_target: str,
    remote_directory: str,
    remote_port: int,
    config: str,
    benchmark_repo: str | None,
) -> int:
    if benchmark_repo is None:
        benchmark_assignment: str = (
            'BENCHMARK_REPO="$HOME/dgx-spark-llm-serving-benchmark"'
        )
    else:
        benchmark_assignment = "BENCHMARK_REPO=" + shlex.quote(benchmark_repo)
    proxy_url: str = f"http://127.0.0.1:{remote_port}"
    remote_script: str = f"{remote_directory}/predownload.sh"
    remote_command: str = (
        f"{benchmark_assignment} "
        f"DOWNLOAD_PROXY={shlex.quote(proxy_url)} "
        f"bash {shlex.quote(remote_script)} {shlex.quote(config)}"
    )
    completed: subprocess.CompletedProcess[bytes] = subprocess.run(
        ["ssh", "-T", ssh_target, remote_command],
        check=False,
    )
    return completed.returncode


def main(argv: list[str]) -> int:
    arguments: Arguments = parse_arguments(argv)
    script_directory: Path = Path(__file__).resolve().parent
    proxy_server: ThreadingConnectProxyServer = ThreadingConnectProxyServer(
        ("127.0.0.1", 0), HfConnectProxyHandler
    )
    local_port: int = int(proxy_server.server_address[1])
    proxy_thread: threading.Thread = threading.Thread(
        target=proxy_server.serve_forever,
        name="hf-connect-proxy",
        daemon=True,
    )
    remote_directory: str | None = None
    tunnel_process: subprocess.Popen[bytes] | None = None
    proxy_thread.start()
    try:
        remote_directory = create_remote_helper_directory(arguments.ssh_target)
        remote_port: int = choose_remote_forward_port(arguments.ssh_target)
        copy_download_helpers(
            arguments.ssh_target, remote_directory, script_directory
        )
        tunnel_process = start_ssh_reverse_forward(
            arguments.ssh_target, remote_port, local_port
        )
        print(
            f"[tunnel] HTTPS downloads from Hugging Face will use the reverse "
            f"forward to {arguments.ssh_target}; model files are written to "
            "the target node's HF cache."
        )
        return run_remote_download(
            arguments.ssh_target,
            remote_directory,
            remote_port,
            arguments.config,
            arguments.benchmark_repo,
        )
    finally:
        stop_ssh_reverse_forward(tunnel_process)
        if remote_directory is not None:
            remove_remote_helper_directory(arguments.ssh_target, remote_directory)
        proxy_server.shutdown()
        proxy_server.server_close()
        proxy_thread.join(timeout=SSH_TERMINATE_WAIT_SECONDS)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (
        OSError,
        RuntimeError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"[tunnel] ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from error
