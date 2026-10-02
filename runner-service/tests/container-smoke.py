"""Real S3 + hardened worker checks. Run with built vulcan-{python,cae,mujoco,blender}:check images.

Uses an isolated Docker network and named test containers; touches no Kubernetes context.
Emits no credentials or pre-signed URLs. --image limits which workload to verify.
"""
import argparse
import concurrent.futures
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import time

import boto3
from botocore.config import Config

parser = argparse.ArgumentParser()
parser.add_argument("--image", choices=["python", "cae", "mujoco", "blender"], default="python")
parser.add_argument("--count", type=int, default=1)
args = parser.parse_args()
run_id = secrets.token_hex(4)
network = f"vulcan-check-{run_id}"
store = f"vulcan-store-{run_id}"
env = {**os.environ, "AWS_ACCESS_KEY_ID": "vulcan-test-" + run_id, "AWS_SECRET_ACCESS_KEY": secrets.token_urlsafe(32)}


def docker(*command, **kwargs):
    return subprocess.run(["docker", *command], check=True, capture_output=True, text=True, **kwargs).stdout.strip()


try:
    docker("network", "create", network)
    docker("run", "-d", "--name", store, "--network", network, "--network-alias", "store",
           "--user", "1000:1000", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
           "--tmpfs", "/data:uid=1000,gid=1000,size=2g", "--tmpfs", "/tmp:uid=1000,gid=1000,size=128m",
           "-p", "127.0.0.1::8333", "-e", "AWS_ACCESS_KEY_ID", "-e", "AWS_SECRET_ACCESS_KEY",
           "chrislusf/seaweedfs:4.48", "mini", "-dir=/data", "-ip=127.0.0.1", "-ip.bind=0.0.0.0",
           "-admin.ui=false", "-s3.port.iceberg=0", "-s3.port.lance=0", "-s3.iam=false", env=env)
    port = docker("port", store, "8333/tcp").split(":")[-1]
    options = dict(aws_access_key_id=env["AWS_ACCESS_KEY_ID"], aws_secret_access_key=env["AWS_SECRET_ACCESS_KEY"],
                   region_name="us-east-1", config=Config(signature_version="s3v4", s3={"addressing_style": "path"},
                   connect_timeout=2, read_timeout=5, retries={"max_attempts": 0}))
    local = boto3.client("s3", endpoint_url=f"http://127.0.0.1:{port}", **options)
    internal = boto3.client("s3", endpoint_url="http://store:8333", **options)
    deadline = time.monotonic() + 90
    while True:
        try:
            local.create_bucket(Bucket="vulcan")
            break
        except Exception:
            if time.monotonic() >= deadline:
                raise RuntimeError("S3 startup failed (credentials/logs redacted)") from None
            time.sleep(1)
    local.put_bucket_lifecycle_configuration(Bucket="vulcan", LifecycleConfiguration={"Rules": [
        {"ID": "seven-days", "Status": "Enabled", "Filter": {"Prefix": ""}, "Expiration": {"Days": 7}}]})
    assert local.get_bucket_lifecycle_configuration(Bucket="vulcan")["Rules"][0]["Expiration"]["Days"] == 7
    def signed(key, method):
        return internal.generate_presigned_url(method, Params={"Bucket": "vulcan", "Key": key}, ExpiresIn=3600)
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w:gz") as archive:
        archive.add(Path(__file__).with_name("cube.inp"), arcname="cube.inp")
    local.put_object(Bucket="vulcan", Key="input.tar.gz", Body=payload.getvalue())
    commands = {
        "python": ["python3", "-c", "import os,pathlib; print('hello '+os.environ['JOB_INDEX']); pathlib.Path('out.txt').write_text(os.environ['JOB_INDEX'])"],
        "cae": ["sh", "-ec", "ccx -i cube; test -s cube.frd; test -s cube.dat; gmsh --version; freecadcmd --version"],
        "mujoco": ["python3", "-c", "import mujoco,numpy,pathlib; m=mujoco.MjModel.from_xml_string('<mujoco><worldbody><body><joint type=\"free\"/><geom type=\"sphere\" size=\".1\"/></body></worldbody></mujoco>'); d=mujoco.MjData(m); mujoco.mj_step(m,d); pathlib.Path('out.txt').write_text(str(d.time)); print(d.time)"],
        "blender": ["blender", "--background", "--factory-startup", "--python-expr", "import bpy; bpy.context.scene.render.engine='CYCLES'; bpy.context.scene.cycles.device='CPU'; bpy.context.scene.cycles.samples=1; bpy.context.scene.cycles.use_denoising=False; bpy.context.scene.render.resolution_x=32; bpy.context.scene.render.resolution_y=32; bpy.context.scene.render.filepath='/work/out.png'; bpy.ops.render.render(write_still=True)"],
    }
    outputs = {"python": ["out.txt"], "cae": ["cube.dat", "cube.frd"], "mujoco": ["out.txt"], "blender": ["out.png"]}
    def task(index):
        task_env = {**env, "JOB_INDEX": str(index), "RUNNER_TASK": json.dumps({"command": commands[args.image], "args": [],
            "env": {}, "working_dir": ".", "inputs": [signed("input.tar.gz", "get_object")], "outputs": outputs[args.image], "timeout": 120})}
        transfer_key = f"RUNNER_TRANSFER_{index}"
        task_env[transfer_key] = json.dumps({kind: signed(f"{index}/{filename}", "put_object") for kind, filename in
            [("output", "outputs.tar.gz"), ("log", "stdout.log"), ("result", "result.json")]})
        result = subprocess.run(["docker", "run", "--rm", "--network", network, "--user", "1000:1000", "--read-only",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", "2", "--memory", "2g",
            "--tmpfs", "/work:uid=1000,gid=1000,size=128m", "--tmpfs", "/tmp:uid=1000,gid=1000,size=256m",
            "-e", "JOB_INDEX", "-e", "RUNNER_TASK", "-e", transfer_key, f"vulcan-{args.image}:check", "python3", "/opt/vulcan/worker.py"],
            env=task_env, capture_output=True, timeout=240)
        receipt = json.loads(local.get_object(Bucket="vulcan", Key=f"{index}/result.json")["Body"].read())
        try:
            logs = local.get_object(Bucket="vulcan", Key=f"{index}/stdout.log")["Body"].read().decode(errors="replace")
        except local.exceptions.NoSuchKey:
            logs = "no task log"
        assert result.returncode == 0 and receipt["exit_code"] == 0 and receipt["outputs_uploaded"], (receipt, logs[-2000:])
        content = local.get_object(Bucket="vulcan", Key=f"{index}/outputs.tar.gz")["Body"].read()
        with tarfile.open(fileobj=io.BytesIO(content)) as archive:
            assert set(outputs[args.image]) <= set(archive.getnames())
            if args.image == "python":
                assert archive.extractfile("out.txt").read().decode() == str(index)
            if args.image == "cae":
                assert "pardiso solver" in logs.lower() and "number of threads = 2" in logs.lower(), logs
                rows = archive.extractfile("cube.dat").read().decode().splitlines()
                displacements = [float(row.split()[1]) for row in rows if len(row.split()) == 4 and row.split()[0] in {"2", "3", "6", "7"}]
                assert len(displacements) == 4 and all(0.0008 < value < 0.0011 for value in displacements), displacements
        return {"index": index, "exit_code": receipt["exit_code"], "wall_seconds": receipt["wall_seconds"], "output_bytes": len(content)}
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(task, range(args.count)))
    print(json.dumps({"environment": "local Docker (not Kubernetes acceptance)", "image": args.image, "tasks": results,
                      "wall_seconds": round(time.monotonic() - started, 3), "s3_lifecycle_configuration": "7 days; expiry not elapsed"}, indent=2))
finally:
    subprocess.run(["docker", "rm", "-f", store], capture_output=True)
    subprocess.run(["docker", "network", "rm", network], capture_output=True)
