"""Run after reviewed Flux activation, from an authorized tailnet machine.

uv run python acceptance.py --fanout --quota --cleanup > evidence/live.json
No access tokens or signed artifact URLs are printed.
"""
import argparse
import asyncio
import io
import json
from pathlib import Path
import tarfile
import time

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

parser = argparse.ArgumentParser()
parser.add_argument("--base", default="https://olympus-vulcan.taild90e78.ts.net")
parser.add_argument("--fanout", action="store_true")
parser.add_argument("--quota", action="store_true")
parser.add_argument("--cleanup", action="store_true")
parser.add_argument("--expect-denied", action="store_true", help="Run on a separate tailnet device WITHOUT a runner grant")
args = parser.parse_args()
http = httpx.Client(base_url=args.base, timeout=60)
report = {"base": args.base, "checks": {}}
created = []


def call(tool, **arguments):
    response = http.post("/api/" + tool, json=arguments)
    response.raise_for_status()
    return response.json()


def wait(job, expected="succeeded", limit=900):
    start = time.monotonic()
    while time.monotonic() - start < limit:
        status = call("job_status", job_id=job)
        if status["state"] == expected:
            return status
        if status["state"] in {"failed", "cancelled", "queue_timeout", "expired_or_removed", "submission_unknown"}:
            raise AssertionError(status)
        time.sleep(2)
    raise TimeoutError(job)


def verify_outputs(job, tasks, cae=False):
    outputs = call("get_outputs", job_id=job)
    receipts, archives = {}, {}
    for entry in outputs["files"]:
        response = http.get(entry["url"])
        response.raise_for_status()
        index, filename = entry["path"].split("/")
        if filename == "result.json":
            receipts[int(index)] = response.json()
        if filename == "outputs.tar.gz":
            archives[int(index)] = response.content
    assert set(receipts) == set(archives) == set(range(tasks))
    for index in range(tasks):
        assert receipts[index]["exit_code"] == 0 and receipts[index]["outputs_uploaded"]
        with tarfile.open(fileobj=io.BytesIO(archives[index])) as archive:
            if cae:
                assert archive.extractfile("cube.dat").read() and archive.extractfile("cube.frd").read()
                assert archive.extractfile("index.txt").read().decode().strip() == str(index)
            else:
                assert archive.extractfile("hello.txt").read() == b"hello"
    return {"tasks": tasks, "archives": len(archives), "receipts": len(receipts), "all_exit_zero": True}


async def mcp_hello(spec):
    async with streamable_http_client(args.base + "/mcp/") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert {t.name for t in tools.tools} == {"submit_job", "job_status", "job_logs", "list_jobs", "cancel_job", "upload_inputs", "get_outputs", "list_images"}
            result = await session.call_tool("submit_job", {"spec": spec})
            assert not result.isError, result
            return json.loads(result.content[0].text)["job_id"]


try:
    if args.expect_denied:
        response = http.post("/api/list_images", json={})
        assert response.status_code in {401, 403}, response.status_code
        report["checks"]["no_grant"] = {"http_status": response.status_code}
    else:
        hello = {"image": "python", "command": ["python3", "-c", "from pathlib import Path; print('hello'); Path('hello.txt').write_text('hello')"],
                 "outputs": ["hello.txt"], "ttl": 300, "labels": {"project": "runner-acceptance", "purpose": "hello"}}
        for transport in ["REST", "MCP"]:
            job = call("submit_job", spec=hello)["job_id"] if transport == "REST" else asyncio.run(mcp_hello(hello))
            created.append(job)
            wait(job)
            logs = call("job_logs", job_id=job)
            assert "hello" in logs["logs"]
            report["checks"][transport] = {"job_id": job, "logs": logs["logs"], **verify_outputs(job, 1)}
        if args.fanout:
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w:gz") as archive:
                archive.add(Path(__file__).parent / "tests/cube.inp", arcname="cube.inp")
            data = payload.getvalue()
            upload = call("upload_inputs", size=len(data))
            http.put(upload["url"], content=data, headers=upload["headers"]).raise_for_status()
            spec = {"image": "cae", "command": ["sh", "-ec", "ccx -i cube; printf '%s' \"$JOB_INDEX\" > index.txt"],
                    "resources": {"cpu": "2", "memory": "1Gi", "ephemeral_storage": "8Gi"}, "parallelism": 37,
                    "inputs": [upload["input"]], "outputs": ["cube.dat", "cube.frd", "index.txt"], "timeout": 120,
                    "labels": {"project": "runner-acceptance", "purpose": "fanout"}}
            start = time.monotonic()
            job = call("submit_job", spec=spec)["job_id"]
            created.append(job)
            status = wait(job)
            report["checks"]["fanout"] = {"job_id": job, "wall_seconds": round(time.monotonic() - start, 3),
                "completed_indexes": status["completed_indexes"], **verify_outputs(job, 37, cae=True)}
        if args.quota:
            occupy = {"image": "python", "command": ["python3", "-c", "import time; time.sleep(120)"], "parallelism": 128, "timeout": 150}
            first = call("submit_job", spec=occupy)["job_id"]
            created.append(first)
            wait(first, "running")
            second = call("submit_job", spec=hello)["job_id"]
            created.append(second)
            time.sleep(10)
            assert call("job_status", job_id=second)["state"] == "queued"
            call("cancel_job", job_id=first)
            wait(second)
            report["checks"]["quota"] = {"first_job": first, "queued_job": second, "queued_then_completed": True,
                "other_identity_progress": "Requires a simultaneous run from the independently granted norma identity"}
        if args.cleanup:
            # Retained final status is expected after the Kubernetes object is deleted.
            deadline = time.monotonic() + 420
            while time.monotonic() < deadline:
                live_ids = {j["job_id"] for j in call("list_jobs")}
                if all(report["checks"][t]["job_id"] not in live_ids for t in ["REST", "MCP"]):
                    break
                time.sleep(10)
            else:
                raise AssertionError("Kubernetes TTL did not remove the hello Jobs")
            report["checks"]["job_ttl"] = "Both 300-second TTL Jobs removed; outputs still retrievable"
            verify_outputs(report["checks"]["REST"]["job_id"], 1)
        report["checks"]["seven_day_artifact_expiry"] = "Pending elapsed retention; record baseline object IDs now and verify absence after seven days"
    print(json.dumps(report, indent=2))
finally:
    # Cancel unfinished jobs only; preserve completed artifacts/evidence for retention checks.
    for job in created:
        try:
            if call("job_status", job_id=job)["state"] in {"queued", "running"}:
                call("cancel_job", job_id=job)
        except Exception:
            pass
    http.close()
