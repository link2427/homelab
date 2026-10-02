import asyncio
import io
import json
import tarfile
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from kubernetes import client

import app
import worker


def configure(monkeypatch):
    profile = {"subjects": ["user:jacob@example.test"], "queue": "jacob", "images": ["python"],
               "quota": {"cpu": "8", "memory": "16Gi", "ephemeral-storage": "64Gi", "pods": 8}}
    monkeypatch.setattr(app, "SETTINGS", {"isolation_verified": True, "profiles": {"jacob": profile, "other": profile},
                                        "images": {"python": {"image": "ghcr.io/link2427/vulcan-python@sha256:" + "a" * 64}}})
    app.ID.set("jacob")
    monkeypatch.setattr(app, "signed", lambda key, *args, **kwargs: "http://store/" + key)
    return profile


def test_manifest_and_caps(monkeypatch):
    profile = configure(monkeypatch)
    spec = app.JobSpec(image="python", command=["python3", "hello.py"], parallelism=37)
    job = app.job_manifest("vulcan-" + "a" * 32, spec, "image", profile, [])
    assert job["spec"]["completions"] == 37
    assert job["spec"]["parallelism"] == 8
    assert job["spec"]["suspend"] is True
    assert job["spec"]["completionMode"] == "Indexed"
    pod = job["spec"]["template"]["spec"]
    assert pod["automountServiceAccountToken"] is False
    assert pod["containers"][0]["securityContext"]["readOnlyRootFilesystem"] is True
    assert pod["containers"][0]["resources"]["limits"] == pod["containers"][0]["resources"]["requests"]
    assert all("hostPath" not in volume for volume in pod["volumes"])
    with pytest.raises(ValueError):
        app.job_manifest("vulcan-" + "a" * 32, app.JobSpec(image="python", command=["true"], resources={"cpu": "9"}), "image", profile, [])


@pytest.mark.parametrize("field,value", [("parallelism", 0), ("parallelism", True), ("timeout", 0), ("ttl", 1),
    ("working_dir", "../bad"), ("outputs", ["/etc/passwd"]), ("outputs", ["a/../../b"]),
    ("env", {"API_KEY": "never-log-this"}), ("env", {"RUNNER_TASK": "{}"}),
    ("resources", {"cpu": "NaN"}), ("resources", {"memory": "-1Gi"}), ("resources", {"cpu": "Infinity"}),
    ("privileged", True)])
def test_validation(field, value):
    with pytest.raises(ValueError):
        app.JobSpec.model_validate({"image": "python", "command": ["true"], field: value})


def archive(name="a.txt", kind=tarfile.REGTYPE, payload=b"hello"):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as tar:
        item = tarfile.TarInfo(name)
        item.type = kind
        item.size = len(payload) if kind == tarfile.REGTYPE else 0
        item.linkname = "/etc/passwd"
        tar.addfile(item, io.BytesIO(payload) if item.size else None)
    stream.seek(0)
    return stream


@pytest.mark.parametrize("name,kind", [("../escape", tarfile.REGTYPE), ("/escape", tarfile.REGTYPE),
    ("link", tarfile.SYMTYPE), ("hard", tarfile.LNKTYPE), ("pipe", tarfile.FIFOTYPE), ("a\\..\\escape", tarfile.REGTYPE)])
def test_reject_hostile_tar(tmp_path, name, kind):
    with pytest.raises(ValueError):
        worker.extract(archive(name, kind), tmp_path)


def test_artifact_roundtrip_and_expansion_limit(tmp_path, monkeypatch):
    worker.extract(archive(), tmp_path)
    assert (tmp_path / "a.txt").read_text() == "hello"
    output = tmp_path.parent / (tmp_path.name + ".tar.gz")
    worker.pack(tmp_path, ["a.txt"], output)
    with tarfile.open(output) as tar:
        assert tar.extractfile("a.txt").read() == b"hello"
    monkeypatch.setattr(worker, "MAX_EXPANDED", 4)
    with pytest.raises(ValueError):
        worker.extract(archive(), tmp_path)


def test_ownership_and_fail_closed(monkeypatch):
    configure(monkeypatch)
    app.batch = Mock()
    app.batch.read_namespaced_job.return_value = SimpleNamespace(metadata=SimpleNamespace(labels={app.OWNER: "other"}))
    with pytest.raises(FileNotFoundError):
        app.owned_job("vulcan-" + "a" * 32)
    app.SETTINGS["isolation_verified"] = False
    with pytest.raises(PermissionError):
        app.submit_job(app.JobSpec(image="python", command=["true"]))
    app.batch.create_namespaced_job.assert_not_called()


def test_allowlist_and_foreign_inputs(monkeypatch):
    configure(monkeypatch)
    app.batch = Mock()
    app.batch.list_namespaced_job.return_value.items = []
    for fields in [{"image": "docker.io/evil:latest"}, {"inputs": ["http://169.254.169.254/"]},
                   {"inputs": ["s3://vulcan/inputs/other/" + "a" * 32 + ".tar.gz"]}]:
        with pytest.raises(ValueError):
            app.submit_job(app.JobSpec.model_validate({"image": "python", "command": ["true"], **fields}))
    app.batch.create_namespaced_job.assert_not_called()


def test_rest_and_mcp_share_inventory_and_auth(monkeypatch):
    configure(monkeypatch)
    app.batch = Mock()
    app.batch.list_namespaced_job.return_value.items = []
    app.s3 = Mock()
    # Exercise real stateless streamable HTTP SDK protocol; only downstream Kube/S3 are replaced.
    async def check():
        import httpx
        async with app.mcp.session_manager.run():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app.app), base_url="http://127.0.0.1:8000") as http:
                denied = await http.post("/api/list_images", json={})
                assert denied.status_code == 401
                headers = {"X-Runner-Identity": "jacob"}
                rest = await http.post("/api/list_images", json={}, headers=headers)
                assert "python" in rest.json()
                headers["Accept"] = "application/json, text/event-stream"
                init = await http.post("/mcp/", headers=headers, json={"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "check", "version": "1"}}})
                assert init.status_code == 200, init.text
                call = await http.post("/mcp/", headers=headers, json={"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_images", "arguments": {}}})
                assert call.status_code == 200, call.text
                assert not call.json()["result"].get("isError"), call.text
                assert "python" in json.loads(call.json()["result"]["content"][0]["text"])
                spec = {"image": "python", "command": ["python3", "-c", "print(42)"], "parallelism": 37}
                submitted = await http.post("/api/submit_job", headers=headers, json={"spec": spec})
                assert submitted.status_code == 200 and submitted.json()["tasks"] == 37, submitted.text
                mcp_submit = await http.post("/mcp/", headers=headers, json={"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "submit_job", "arguments": {"spec": spec}}})
                assert not mcp_submit.json()["result"].get("isError"), mcp_submit.text
                assert json.loads(mcp_submit.json()["result"]["content"][0]["text"])["tasks"] == 37
                assert app.batch.create_namespaced_job.call_count == 2
                oversized = await http.post("/mcp/", headers=headers, content=b"x" * 1500001)
                assert oversized.status_code == 413
    asyncio.run(check())


def test_kubernetes_deserialization(monkeypatch):
    profile = configure(monkeypatch)
    manifest = app.job_manifest("vulcan-" + "a" * 32, app.JobSpec(image="python", command=["true"]), "image", profile, [])
    response = SimpleNamespace(data=json.dumps(manifest))
    job = client.ApiClient().deserialize(response, "V1Job")
    job.status = client.V1JobStatus()
    assert app.summarize(job)["state"] == "queued"


def test_input_download_retries_transport_without_leaking_url(tmp_path, monkeypatch):
    import urllib.error
    attempts = []
    def open_url(url, timeout):
        attempts.append(url)
        if len(attempts) < 3:
            raise urllib.error.URLError("connection refused")
        return io.BytesIO(b"input")
    monkeypatch.setattr(worker.urllib.request, "urlopen", open_url)
    monkeypatch.setattr(worker.time, "sleep", lambda _: None)
    target = tmp_path / "input.tar"
    worker.download_input("http://store/private?signature=secret", target)
    assert target.read_bytes() == b"input" and len(attempts) == 3
    monkeypatch.setattr(worker, "MAX_INPUT", 2)
    with pytest.raises(ValueError):
        worker.download_input("http://store/private", target)
    def forbidden(url, timeout):
        raise urllib.error.HTTPError(url, 403, "Forbidden", {}, None)
    monkeypatch.setattr(worker.urllib.request, "urlopen", forbidden)
    with pytest.raises(urllib.error.HTTPError):
        worker.download_input("http://store/private", target)
