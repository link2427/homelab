"""Unprivileged worker; only per-object expiring URLs, never S3 or cluster credentials."""
import io
import json
import os
from pathlib import Path, PurePosixPath
import signal
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request

MAX_INPUT = 1024**3
MAX_EXPANDED = 4 * 1024**3
MAX_OUTPUT = 2 * 1024**3
MAX_LOG = 20 * 1024**2


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value or "\x00" in value:
        raise ValueError("paths must be relative to /work without traversal")
    return path


def extract(source, destination):
    """Streaming extraction: reject links/devices/traversal and cap expansion/count."""
    total = 0
    with tarfile.open(fileobj=source, mode="r|*") as archive:
        for count, member in enumerate(archive, 1):
            relative_path(member.name)
            if count > 10000 or not (member.isfile() or member.isdir()):
                raise ValueError("tar contains links/special files or too many entries")
            total += member.size
            if total > MAX_EXPANDED:
                raise ValueError("expanded inputs exceed 4 GiB")
            archive.extract(member, destination, filter="data")


def pack(root, paths, target):
    total = 0
    seen = set()
    with tarfile.open(target, "w:gz", dereference=False) as archive:
        for requested in paths:
            relative_path(requested)
            path = root / requested
            if not path.exists() or path.is_symlink():
                raise ValueError("missing output or symlink")
            for item in [path, *path.rglob("*")] if path.is_dir() else [path]:
                relative = item.relative_to(root)
                if str(relative) in seen:
                    continue
                seen.add(str(relative))
                if len(seen) > 10000 or item.is_symlink() or not (item.is_file() or item.is_dir()):
                    raise ValueError("unsupported output or too many files")
                # Resolve parents too, so a requested subdirectory cannot escape via a link.
                item.resolve().relative_to(root.resolve())
                total += item.stat().st_size if item.is_file() else 0
                if total > MAX_OUTPUT:
                    raise ValueError("outputs exceed 2 GiB")
                archive.add(item, arcname=str(relative), recursive=False)


def put(url, path):
    for attempt in range(3):
        try:
            with open(path, "rb") as body:
                request = urllib.request.Request(url, data=body, method="PUT",
                    headers={"Content-Length": str(path.stat().st_size)})
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 200:
                        raise RuntimeError("artifact upload failed")
            return
        except Exception:
            if attempt == 2:
                raise RuntimeError("artifact upload failed (URL redacted)") from None
            time.sleep(2**attempt)


def download_input(url, path):
    # New pod policy rules can converge after the process starts. Retry transport
    # failures only; truncate partial downloads and retain the size boundary.
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=120) as response, path.open("wb") as output:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_INPUT:
                        raise ValueError("compressed input exceeds 1 GiB")
                    output.write(chunk)
            return
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 4:
                raise RuntimeError("input download failed (URL redacted)") from None
            time.sleep(2**attempt)


def run(spec, root=Path("/work")):
    root.mkdir(exist_ok=True)
    index = os.environ.get("JOB_INDEX", "0")
    transfer = json.loads(os.environ.pop(f"RUNNER_TRANSFER_{index}"))
    start = time.monotonic()
    result = {"index": int(index), "exit_code": 1, "outputs_uploaded": False}
    log_path = Path("/tmp/task.log")
    try:
        for number, url in enumerate(spec["inputs"]):
            download = Path(f"/tmp/input-{number}.tar")
            download_input(url, download)
            with download.open("rb") as stream:
                extract(stream, root)
            download.unlink()
        relative_path(spec["working_dir"])
        cwd = root / spec["working_dir"]
        cwd.mkdir(parents=True, exist_ok=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith("RUNNER_")}
        env.update(spec["env"])
        env["JOB_INDEX"] = index
        with log_path.open("wb") as logfile:
            process = subprocess.Popen(spec["command"] + spec["args"], cwd=cwd, env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            def terminate(*_):
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    killer = threading.Timer(5, lambda: kill_group(process.pid))
                    killer.daemon = True
                    killer.start()
                except ProcessLookupError:
                    pass
            signal.signal(signal.SIGTERM, terminate)
            # A separate process-group timer leaves time for artifact upload before the Job deadline.
            timer = threading.Timer(spec["timeout"], terminate)
            timer.start()
            count = 0
            try:
                while chunk := process.stdout.read1(65536):
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    remaining = max(0, MAX_LOG - count)
                    logfile.write(chunk[:remaining])
                    count += len(chunk)
                result["exit_code"] = process.wait()
            finally:
                timer.cancel()
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        output = Path("/tmp/outputs.tar.gz")
        pack(root, spec["outputs"], output)
        put(transfer["output"], output)
        result["outputs_uploaded"] = True
    except Exception as exc:
        # URL-bearing exceptions must never disclose pre-signed URLs to logs.
        print(f"runner task failed: {type(exc).__name__}", file=sys.stderr)
        result["error"] = type(exc).__name__
    finally:
        if log_path.exists():
            put(transfer["log"], log_path)
        result["wall_seconds"] = round(time.monotonic() - start, 3)
        result_path = Path("/tmp/result.json")
        result_path.write_text(json.dumps(result))
        put(transfer["result"], result_path)
    return 0 if result["exit_code"] == 0 and result["outputs_uploaded"] else 1


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


if __name__ == "__main__":
    sys.exit(run(json.loads(os.environ.pop("RUNNER_TASK"))))
