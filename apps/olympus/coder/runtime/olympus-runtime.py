#!/usr/bin/env python3
"""Shared, unprivileged Olympus harness lifecycle. No provider calls or task resume."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.error
import uuid

RUNTIME = Path(__file__).resolve().parent
TOOLS = json.loads((RUNTIME / "tools.json").read_text())
HOME = Path.home()
STATE = Path(os.environ.get("OLYMPUS_STATE", HOME / ".local/state/olympus"))
ROOT = Path(os.environ.get("OLYMPUS_TOOL_ROOT", HOME / ".local/share/olympus/tools"))
BASE = Path(os.environ.get("OLYMPUS_BASELINE", "/opt/olympus/tools"))
BIN = Path("/opt/olympus/bin")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.+_-]*$")


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".writing-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {} if default is None else default


@contextlib.contextmanager
def lock(name, shared=False, blocking=False):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / (name + ".lock")).open("a") as stream:
        flags = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
        fcntl.flock(stream, flags | (0 if blocking else fcntl.LOCK_NB))
        yield stream


def fetch(url, binary=False):
    request = urllib.request.Request(url, headers={"User-Agent": "Olympus-Coder/1"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(4 * 1024 * 1024)
                if len(data) >= 4 * 1024 * 1024:
                    raise ValueError("Release metadata exceeds size limit")
                return data if binary else json.loads(data)
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def download(url, destination, digest=None):
    # curl has a total deadline, unlike an unbounded streaming socket timeout.
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "2", "--connect-timeout", "15", "--max-time", "300",
                    "--max-filesize", "1073741824", "--output", str(destination), url],
                   check=True, timeout=930)
    with destination.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest and actual != digest.removeprefix("sha256:"):
        raise ValueError("Release checksum mismatch")
    return actual


def latest(tool):
    spec = TOOLS[tool]
    if "package" in spec:
        data = fetch("https://registry.npmjs.org/" + spec["package"] + "/latest")
        return data["version"], {"source": spec["package"] + "@" + data["version"],
                                  "integrity": data["dist"].get("integrity", "")}
    if "release" in spec:
        data = fetch("https://api.github.com/repos/" + spec["release"] + "/releases/latest")
        version = data["tag_name"].removeprefix("v")
        asset = next(a for a in data["assets"] if a["name"] == f"prime-agent-{version}.tgz")
        if not asset.get("digest"):
            raise ValueError("Official release is missing its checksum")
        return version, {"source": asset["browser_download_url"], "digest": asset["digest"]}
    version = fetch(spec["channel"], binary=True).decode().strip().splitlines()[0]
    return version, {"source": f"https://x.ai/cli/grok-{version}-linux-x86_64"}


def selected(tool):
    for root in (ROOT, BASE):
        link = root / tool / "current"
        if link.is_symlink() and (link / "ready.json").exists():
            return link.resolve()
    raise RuntimeError(f"{tool} is unavailable; run olympus-agent-update {tool} or open Diagnostics")


def binary(tool, directory):
    return directory / "bin" / TOOLS[tool]["bin"]


def env_for(tool, directory, home=None, offline=True):
    env = os.environ.copy()
    env.update({"PATH": f"{BIN}:/usr/local/bin:/usr/bin:/bin:" + env.get("PATH", ""),
                "DISABLE_AUTOUPDATER": "1", "OPENCODE_DISABLE_AUTOUPDATE": "true", "GROK_DISABLE_AUTOUPDATER": "1",
                "PRIME_AGENT_INSTALL_UV": "1", "UV_PYTHON": "/opt/olympus/python/bin/python3",
                "UV_PYTHON_DOWNLOADS": "never"})
    if home:
        env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   XDG_DATA_HOME=str(home / ".local/share"), XDG_CACHE_HOME=str(home / ".cache"))
        # Never let a smoke test consume production credentials.
        for key in list(env):
            if any(word in key for word in ("API_KEY", "TOKEN", "SECRET", "PASSWORD")):
                del env[key]
    if tool == "openhands":
        env["UV_CACHE_DIR"] = str(directory / "uv-cache")
        if offline:
            env["UV_OFFLINE"] = "true"
        else:
            env.pop("UV_OFFLINE", None)
    return env


def run_checked(args, log, env=None, timeout=600, cwd=None):
    process = subprocess.Popen([str(x) for x in args], stdout=log, stderr=log,
                               env=env, cwd=cwd, start_new_session=True)
    try:
        rc = process.wait(timeout=timeout)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    if rc:
        raise RuntimeError(f"{Path(str(args[0])).name} exited {rc}; see the installation log")


def warm_canvas(directory, log, env):
    package = directory / "lib/node_modules/@openhands/agent-canvas"
    # Ask the installed release for its exact dependency/constraint set.
    code = "import {buildAgentServerCommand} from " + json.dumps((package / "scripts/dev-safe.mjs").as_uri()) + ";console.log(JSON.stringify(buildAgentServerCommand().args));"
    args = json.loads(subprocess.check_output(["node", "--input-type=module", "-e", code], env=env, timeout=30))
    pos = args.index("agent-server")
    run_checked(["uvx", *args[:pos], "python", "-c", "import openhands.agent_server"], log, env, 600)
    defaults = json.loads((package / "config/defaults.json").read_text())
    automation = defaults["versions"]["automation"]
    run_checked(["uvx", "--from", f"openhands-automation=={automation}", "python", "-c",
                 "import openhands.automation.app"], log, env, 600)


def smoke_web(tool, directory, log, env, testhome):
    """Check a candidate server with isolated state before allowing promotion."""
    if tool not in ("reasonix", "deepseek", "openhands"):
        return
    sockets = []
    try:
        for _ in range(6):
            sock = socket.socket()
            sock.bind(('127.0.0.1', 0))
            sockets.append(sock)
        ports = [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()
    env = env.copy()
    instance = uuid.uuid4().hex
    env['OLYMPUS_SERVICE_INSTANCE'] = instance
    port = ports[0]
    if tool == 'reasonix':
        args = ['serve', '--addr', f'127.0.0.1:{port}', '--auth', 'none']
    elif tool == 'deepseek':
        args = ['web', '--no-open', '--host', '127.0.0.1', '--port', str(port)]
        shutil.copytree(directory / 'dsh-seed', testhome / '.dsh', dirs_exist_ok=True, symlinks=True)
        env['DSH_HOME'] = str(testhome / '.dsh')
    else:
        args = ['--port', str(port)]
        env.update(OH_CANVAS_SAFE_BACKEND_PORT=str(ports[1]), OH_CANVAS_SAFE_AUTOMATION_PORT=str(ports[2]),
                   OH_CANVAS_SAFE_VITE_PORT=str(ports[3]), OH_CANVAS_SAFE_VSCODE_PORT=str(ports[4]), UV_OFFLINE='true')
    process = subprocess.Popen([str(binary(tool, directory)), *args], env=env, cwd=testhome,
                               stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Candidate web service exited before becoming ready')
            try:
                try:
                    response = urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=2)
                except urllib.error.HTTPError as error:
                    if tool != 'deepseek' or error.code != 401:
                        raise
                    response = error  # DSH's mandatory login fence is expected here.
                response.close()
                if tool == 'openhands':
                    urllib.request.urlopen(f'http://127.0.0.1:{ports[1]}/health', timeout=2).close()
                return
            except (OSError, ValueError):
                time.sleep(1)
        raise RuntimeError('Candidate web service failed its readiness check')
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        reap_instance(instance)
        if tool == 'deepseek':
            # Never bake shared browser credentials or telemetry identity into an image.
            for name in ('.credentials.yaml', '.anonymous-user-id'):
                (directory / 'dsh-seed' / name).unlink(missing_ok=True)


def install(tool, version, release, baseline=False):
    if not VERSION.fullmatch(version):
        raise ValueError("Invalid version in release metadata")
    directory = ROOT / tool / version
    if (directory / "ready.json").exists():
        return directory
    if shutil.disk_usage(ROOT).free < 3 * 1024 ** 3:
        raise RuntimeError("Less than 3 GiB free; retaining installed tools")
    if directory.exists():
        # Only an incomplete install beneath the dedicated tool root is removable.
        directory.resolve().relative_to(ROOT.resolve())
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    (STATE / "logs").mkdir(parents=True, exist_ok=True)
    logpath = STATE / "logs" / f"install-{tool}.log"
    if logpath.exists() and logpath.stat().st_size > 5 * 1024 ** 2:
        os.replace(logpath, logpath.with_suffix(".log.1"))
    with logpath.open("a") as log, tempfile.TemporaryDirectory(prefix="olympus-test-") as tmp:
        testhome = Path(tmp)
        env = env_for(tool, directory, home=testhome, offline=False)
        print(f"\n{now()} installing {tool} {version}", file=log, flush=True)
        if tool == "grok":
            (directory / "bin").mkdir()
            release["sha256"] = download(release["source"], binary(tool, directory))
            binary(tool, directory).chmod(0o755)
        else:
            source = release["source"]
            if tool == "prime-agent":
                archive = directory / "release.tgz"
                download(source, archive, release["digest"])
                source = str(archive)
            run_checked(["npm", "install", "--global", "--prefix", directory,
                         "--no-audit", "--no-fund", "--loglevel=error", "--progress=false", source], log, env, 600)
        run_checked([binary(tool, directory), "--version"], log, env, 45)
        run_checked([binary(tool, directory), "--help"], log, env, 45)
        if tool == "openhands":
            warm_canvas(directory, log, env)
        if tool == "deepseek":
            env["DSH_HOME"] = str(directory / "dsh-seed")
            run_checked([binary(tool, directory), "web", "--help"], log, env, 600)
        smoke_web(tool, directory, log, env, testhome)
        atomic_json(directory / "ready.json", {"version": version, "installed_at": now(), **release})
    return directory


def promote(tool, directory):
    parent = ROOT / tool
    parent.mkdir(parents=True, exist_ok=True)
    try:
        previous = selected(tool)
    except RuntimeError:
        previous = None
    if previous and previous != directory:
        atomic_json(STATE / (tool + '-previous.json'), {'path': str(previous), 'version': previous.name})
    target = parent / ".current-next"
    target.unlink(missing_ok=True)
    target.symlink_to(directory)
    os.replace(target, parent / "current")


def cleanup(tool):
    parent = ROOT / tool
    versions = sorted((p.parent for p in parent.glob("*/ready.json") if p.parent.name != "current"),
                      key=lambda p: read_json(p / "ready.json").get("installed_at", ""), reverse=True)
    keep = set(versions[:2]) | {selected(tool)}
    previous = read_json(STATE / (tool + '-previous.json')).get('path')
    if previous:
        keep.add(Path(previous))
    pending = read_json(STATE / f"{tool}.json").get("pending")
    for directory in versions:
        if directory in keep or directory.name == pending:
            continue
        try:
            with lock("lease-" + tool + "-" + directory.name):
                directory.resolve().relative_to(ROOT.resolve())
                shutil.rmtree(directory)
        except BlockingIOError:
            pass


def update(tool_names, baseline=False):
    ROOT.mkdir(parents=True, exist_ok=True)
    failures = 0
    try:
        with lock("update"):
            for tool in tool_names:
                validated = False
                status = read_json(STATE / f"{tool}.json")
                status.update(checked_at=now())
                try:
                    version, release = latest(tool)
                    status["available"] = version
                    directory = install(tool, version, release, baseline)
                    validated = True
                    try:
                        old = selected(tool).name
                    except RuntimeError:
                        old = ""
                    # Major migrations require explicit adoption; binaries are already staged.
                    if old and old.split(".")[0] != version.split(".")[0] and not baseline:
                        status.update(pending=version, error="Major version staged; review migration, then olympus-adopt " + tool)
                    else:
                        promote(tool, directory)
                        status.update(selected=version, pending=None, error=None, succeeded_at=now())
                    print(f"{tool}: {version}" + (" (pending adoption)" if status.get("pending") else ""), flush=True)
                except Exception as exc:
                    failures += 1
                    # Avoid dumping subprocess environments, auth headers, or full responses.
                    status["error"] = f"{type(exc).__name__}: {str(exc)[:240]}"
                    print(f"{tool}: update failed; working version retained", file=sys.stderr, flush=True)
                atomic_json(STATE / f"{tool}.json", status)
                if not baseline and validated:
                    cleanup(tool)
                if baseline and failures:
                    return 1
            atomic_json(STATE / "last-update.json", {"finished_at": now(), "failures": failures})
    except BlockingIOError:
        print("Update already in progress")
    return int(failures > 0)


def launch(tool, args):
    directory = selected(tool)
    env = env_for(tool, directory)
    env.update(OLYMPUS_RUNNING_TOOL=tool, OLYMPUS_RUNNING_VERSION=directory.name)
    marker = STATE / "config-versions" / (tool + ".json")
    with lock("config-" + tool, blocking=True):
        if read_json(marker).get("version") != directory.name:
            recovery = snapshot_config(tool)
            atomic_json(marker, {"version": directory.name, "recovery": str(recovery)})
    if tool == "deepseek" and not (HOME / ".dsh").exists() and (directory / "dsh-seed").exists():
        shutil.copytree(directory / "dsh-seed", HOME / ".dsh", symlinks=True)
    # A shared lock lives for the whole process tree, so cleanup cannot remove its libraries.
    with lock("lease-" + tool + "-" + directory.name, shared=True, blocking=True) as lease:
        os.set_inheritable(lease.fileno(), True)
        os.execve(binary(tool, directory), [str(binary(tool, directory)), *args], env)


def snapshot_config(tool):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    destination = STATE / "recovery" / f"{tool}-{stamp}.tar.gz"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(destination, "w:gz") as archive:
        for item in TOOLS[tool]["config"]:
            path = HOME / item
            if path.exists():
                archive.add(path, arcname=item, filter=lambda info: None if any(
                    part in ("node_modules", ".cache", "downloads", "cache", "uv-cache")
                    for part in Path(info.name).parts) else info)
    destination.chmod(0o600)
    for old in sorted(destination.parent.glob(tool + '-*.tar.gz'), reverse=True)[5:]:
        old.unlink()
    return destination


def adopt(tool, rollback=False):
    with lock("update"):
        current = selected(tool)
        candidates = [p for root in (ROOT, BASE) for p in (root / tool).glob("*/ready.json") if p.parent.name != 'current']
        versions = {p.parent.name: p.parent for p in candidates}
        status = read_json(STATE / f"{tool}.json")
        if rollback:
            prior = read_json(STATE / (tool + '-previous.json'))
            target = versions.get(prior.get('version'))
            if target is None or target.name == current.name:
                raise RuntimeError("No previous installation is available")
        else:
            target = versions.get(status.get("pending") or status.get("available"))
            if target is None:
                raise RuntimeError("No validated candidate is available")
        recovery = snapshot_config(tool)
        promote(tool, target)
        status.update(selected=target.name, pending=None, error=None)
        atomic_json(STATE / f"{tool}.json", status)
        print(f"{tool}: new sessions use {target.name}. Configuration saved at {recovery}.")
        print("Existing sessions and web services continue until you restart them.")


def running_versions():
    result = {tool: set() for tool in TOOLS}
    for path in Path('/proc').glob('[0-9]*/environ'):
        try:
            values = dict(value.split(b'=', 1) for value in path.read_bytes().split(b'\0')
                          if value.startswith(b'OLYMPUS_RUNNING_') and b'=' in value)
            tool = values.get(b'OLYMPUS_RUNNING_TOOL', b'').decode()
            version = values.get(b'OLYMPUS_RUNNING_VERSION', b'').decode()
            if tool in result and VERSION.fullmatch(version):
                result[tool].add(version)
        except (OSError, ValueError):
            pass
    return result


def doctor(compact=False):
    entries = []
    for tool in TOOLS:
        data = read_json(STATE / f"{tool}.json")
        try:
            version = selected(tool).name
        except RuntimeError:
            version = "unavailable"
        entries.append((tool, version, data.get("available", "unchecked"), data.get("error", "")))
    if compact:
        failed = sum(bool(e[3]) or e[1] == "unavailable" for e in entries)
        print(f"{len(entries) - failed}/{len(entries)} tools ready; " + (f"{failed} need attention" if failed else "updates every 15m"))
    else:
        running = running_versions()
        print(f"{'HARNESS':15} {'NEW SESSIONS':18} {'RUNNING':18} {'LATEST':18} STATUS")
        for tool, version, available, error in entries:
            active = ','.join(sorted(running[tool])) or '-'
            print(f"{tool:15} {version:18} {active:18} {available:18} {error or 'Ready'}")
        print('Last update check:', read_json(STATE / 'last-update.json').get('finished_at', 'not checked yet'))
        print("\nRunning sessions keep their versions. Saved tasks resume only when you choose.")
        print("\nolympus-agent-update [tool]   Check and stage releases")
        print("olympus-adopt TOOL           Adopt a staged major update")
        print("olympus-rollback TOOL        Select the previous installation")
        print("olympus-services status      Inspect supervised browser services")
        print("olympus-services restart NAME  Restart a service after finishing its tasks")
        print(f"\nLogs: {STATE / 'logs'}")
        if (STATE / "supervisor.sock").exists():
            sys.stdout.flush()
            subprocess.run(["supervisorctl", "-c", str(STATE / "supervisord.conf"), "status"])


def initialize():
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "logs").mkdir(exist_ok=True)
    for path in (HOME / "project", HOME / "exports", HOME / ".local/bin", HOME / ".local/share/filebrowser"):
        path.mkdir(parents=True, exist_ok=True)
    # Put managed launchers before legacy npm prefixes without removing user tools.
    profile = HOME / ".profile"
    existing = profile.read_text() if profile.exists() else ""
    line = 'export PATH="/opt/olympus/bin:/usr/local/bin:$HOME/.local/bin:$PATH"'
    if line not in existing:
        profile.write_text(existing + "\n" + line + "\n")
    for name in [* [v["bin"] for v in TOOLS.values()], "olympus-session", "olympus-agent-update", "olympus-doctor", "olympus-services", "olympus-export", "olympus-adopt", "olympus-rollback"]:
        destination = HOME / ".local/bin" / name
        if not destination.exists() and not destination.is_symlink():
            destination.symlink_to(BIN / name)
    workspace = os.environ.get("OLYMPUS_WORKSPACE_DIR", str(HOME / "project"))
    Path(workspace).mkdir(parents=True, exist_ok=True)
    config = f"""[unix_http_server]
file={STATE}/supervisor.sock
chmod=0600
[supervisord]
logfile={STATE}/logs/supervisord.log
logfile_maxbytes=5MB
logfile_backups=2
pidfile={STATE}/supervisord.pid
childlogdir={STATE}/logs
[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface
[supervisorctl]
serverurl=unix://{STATE}/supervisor.sock
"""
    for service in ("editor", "exports", "reasonix", "deepseek", "openhands"):
        config += f"""
[program:{service}]
command=/usr/bin/python3 {RUNTIME}/olympus-runtime.py serve {service}
directory={workspace}
autostart=true
autorestart=true
startsecs=3
startretries=3
stopsignal=TERM
stopasgroup=true
killasgroup=true
stopwaitsecs=15
stdout_logfile={STATE}/logs/{service}.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=2
redirect_stderr=true
"""
    (STATE / "supervisord.conf").write_text(config)
    # Fresh pods have a new process namespace; supervisord verifies its socket itself.
    alive = subprocess.run(["supervisorctl", "-c", str(STATE / "supervisord.conf"), "pid"], capture_output=True).returncode == 0
    if not alive:
        (STATE / "supervisor.sock").unlink(missing_ok=True)
        subprocess.run(["supervisord", "-c", str(STATE / "supervisord.conf")], check=True)
    print("Olympus runtime ready; downloads run separately from login.")


def reap_instance(instance):
    """Also find descendants that created their own process groups."""
    for path in Path('/proc').glob('[0-9]*/environ'):
        try:
            if not instance or ('OLYMPUS_SERVICE_INSTANCE=' + instance).encode() not in path.read_bytes().split(b'\0'):
                continue
            pid = int(path.parent.name)
            if pid != os.getpid():
                os.kill(pid, signal.SIGKILL)
        except (OSError, ValueError):
            pass


def prepare_service(name):
    """Reap only this supervisor program's descendants after launcher crashes."""
    marker = STATE / 'services' / (name + '.json')
    namespace = os.readlink('/proc/self/ns/pid')
    previous = read_json(marker)
    if previous.get('namespace') == namespace:
        reap_instance(previous.get('instance', ''))
    instance = uuid.uuid4().hex
    atomic_json(marker, {'namespace': namespace, 'group': os.getpgrp(), 'instance': instance})
    os.environ['OLYMPUS_SERVICE_INSTANCE'] = instance


def serve(name):
    prepare_service(name)
    if name == "editor":
        os.execvp("/usr/local/bin/code-server", ["code-server", "--bind-addr", "127.0.0.1:13337", "--auth", "none", "--disable-telemetry", os.getcwd()])
    if name == "exports":
        os.execvp("/usr/local/bin/filebrowser", ["filebrowser", "--address", "127.0.0.1", "--port", "13339", "--root", str(HOME / "exports"), "--database", str(HOME / ".local/share/filebrowser/filebrowser.db"), "--baseURL", os.environ.get("OLYMPUS_EXPORTS_BASE_PATH", ""), "--noauth"])
    if name == "reasonix":
        launch(name, ["serve", "--addr", "127.0.0.1:8787", "--auth", "none"])
    elif name == "deepseek":
        os.execvp("node", ["node", str(RUNTIME / "deepseek-entry.mjs")])
    elif name == "openhands":
        os.environ.update(OH_CANVAS_SAFE_BACKEND_PORT="13342", OH_CANVAS_SAFE_AUTOMATION_PORT="13343", OH_CANVAS_SAFE_VITE_PORT="13344", OH_CANVAS_SAFE_VSCODE_PORT="13345")
        launch(name, ["--port", "13341"])


def main():
    os.umask(0o077)
    if len(sys.argv) > 2 and sys.argv[1] == "run":
        return launch(sys.argv[2], sys.argv[3:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["update", "run", "init", "doctor", "adopt", "rollback", "serve"])
    parser.add_argument("args", nargs="*")
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--compact", action="store_true")
    args, extra = parser.parse_known_args()
    if args.command == "update":
        names = args.args or list(TOOLS)
        if any(t not in TOOLS for t in names):
            parser.error("Unknown harness")
        return update(names, args.baseline)
    if args.command == "run":
        return launch(args.args[0], args.args[1:] + extra)
    if args.command == "init":
        initialize()
    elif args.command == "doctor":
        doctor(args.compact)
    elif args.command == "serve":
        serve(args.args[0])
    else:
        adopt(args.args[0], rollback=args.command == "rollback")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Olympus: {error}", file=sys.stderr)
        sys.exit(1)
