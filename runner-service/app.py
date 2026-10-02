"""Vulcan: one REST/MCP submission path; Kubernetes and Kueue own execution."""
import asyncio
from contextlib import asynccontextmanager
from contextvars import ContextVar
from datetime import datetime, timezone
import json
import logging
import math
import os
from pathlib import Path
import re
import uuid
from functools import wraps

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from kubernetes import client, config
from kubernetes.utils.quantity import parse_quantity
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import BaseModel, ConfigDict, Field, field_validator
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, StreamingResponse
from starlette.routing import Mount, Route

from worker import relative_path

NAMESPACE = "vulcan-jobs"
BUCKET = "vulcan"
OWNER = "vulcan.olympus/identity"
JOB_ID = re.compile(r"^vulcan-[a-f0-9]{32}$")
UPLOAD_ID = re.compile(r"^[a-f0-9]{32}$")
ID = ContextVar("identity", default="")
LOG = logging.getLogger("vulcan.audit")
SETTINGS = {}
batch = core = s3 = external_s3 = None


class Resources(BaseModel):
    model_config = ConfigDict(extra="forbid")
    cpu: str = "1"
    memory: str = "1Gi"
    ephemeral_storage: str = "8Gi"
    gpu: int = Field(default=0, ge=0, le=1, strict=True)

    @field_validator("cpu", "memory", "ephemeral_storage")
    @classmethod
    def positive_quantity(cls, value):
        if len(value) > 24:
            raise ValueError("invalid resource quantity")
        try:
            number = parse_quantity(value)
            if not number.is_finite() or number <= 0:
                raise ValueError("resource quantity must be positive and finite")
        except Exception as exc:
            raise ValueError("invalid resource quantity") from exc
        return value


class JobSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")
    image: str = Field(min_length=1, max_length=256)
    command: list[str] = Field(min_length=1, max_length=32)
    args: list[str] = Field(default_factory=list, max_length=128)
    env: dict[str, str] = Field(default_factory=dict, max_length=32)
    working_dir: str = "."
    resources: Resources = Field(default_factory=Resources)
    parallelism: int = Field(default=1, ge=1, le=128, strict=True)
    inputs: list[str] = Field(default_factory=list, max_length=4)
    outputs: list[str] = Field(default_factory=list, max_length=32)
    timeout: int = Field(default=600, ge=1, le=86400, strict=True)
    ttl: int = Field(default=86400, ge=300, le=604800, strict=True)
    labels: dict[str, str] = Field(default_factory=dict, max_length=3)

    @field_validator("working_dir")
    @classmethod
    def work_path(cls, value):
        relative_path(value)
        return value

    @field_validator("outputs")
    @classmethod
    def output_paths(cls, values):
        for value in values:
            relative_path(value)
        return values

    @field_validator("env")
    @classmethod
    def environment(cls, values):
        for key, value in values.items():
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", key) or len(value) > 4096 or "\x00" in value:
                raise ValueError("invalid environment entry")
            if re.search(r"SECRET|TOKEN|PASSWORD|CREDENTIAL|PRIVATE_KEY|API_KEY", key, re.I):
                raise ValueError("secrets must not be supplied inline")
            if key.startswith(("RUNNER_", "AWS_", "KUBERNETES_")) or key in {"JOB_INDEX", "PYTHONPATH", "PYTHONHOME", "LD_PRELOAD"}:
                raise ValueError("reserved environment name")
        return values

    @field_validator("command", "args")
    @classmethod
    def command_values(cls, values):
        if any(not isinstance(x, str) or len(x) > 8192 or "\x00" in x for x in values):
            raise ValueError("invalid command argument")
        return values

    @field_validator("labels")
    @classmethod
    def job_labels(cls, values):
        if set(values) - {"caller", "project", "purpose"}:
            raise ValueError("labels must be caller, project or purpose")
        if any(not re.fullmatch(r"[a-zA-Z0-9]([a-zA-Z0-9_.-]{0,61}[a-zA-Z0-9])?", v) for v in values.values()):
            raise ValueError("invalid label value")
        return values


def policy():
    identity = ID.get()
    if identity not in SETTINGS["profiles"]:
        raise PermissionError("authorized Tailscale identity required")
    return identity, SETTINGS["profiles"][identity]


def prefix(job_id):
    if not JOB_ID.fullmatch(job_id):
        raise ValueError("invalid job ID")
    identity, _ = policy()
    return f"jobs/{identity}/{job_id}/"


def store_json(key, value):
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(value).encode(), ContentType="application/json")


def read_json(key):
    try:
        return json.loads(s3.get_object(Bucket=BUCKET, Key=key)["Body"].read())
    except ClientError as exc:
        if exc.response["Error"]["Code"] in {"NoSuchKey", "404"}:
            raise FileNotFoundError("not found or expired") from None
        raise


def signed(key, method, public=False, size=None):
    params = {"Bucket": BUCKET, "Key": key}
    if size is not None:
        params["ContentLength"] = size
    return (external_s3 if public else s3).generate_presigned_url(
        method, Params=params, ExpiresIn=900 if public else 172800)


def upload_inputs(size: int, payload_base64: str = "") -> dict:
    """Reserve an input tarball. PUT exactly size bytes to URL; optional <=1 MiB base64."""
    import base64
    identity, _ = policy()
    if type(size) is not int or not 1 <= size <= 1024**3:
        raise ValueError("input size must be 1 byte through 1 GiB")
    upload = uuid.uuid4().hex
    key = f"inputs/{identity}/{upload}.tar.gz"
    if payload_base64:
        if len(payload_base64) > 1400000:
            raise ValueError("inline input exceeds 1 MiB")
        data = base64.b64decode(payload_base64, validate=True)
        if len(data) != size or size > 1024**2:
            raise ValueError("payload size mismatch or exceeds 1 MiB")
        s3.put_object(Bucket=BUCKET, Key=key, Body=data)
        return {"input": f"s3://{BUCKET}/{key}", "uploaded": True}
    return {"input": f"s3://{BUCKET}/{key}", "url": signed(key, "put_object", True, size),
            "method": "PUT", "headers": {"Content-Length": str(size)}, "expires_in": 900}


def list_images() -> dict:
    """List this identity's approved, immutable workload images."""
    _, profile = policy()
    return {name: value for name, value in SETTINGS["images"].items() if name in profile["images"]}


def job_manifest(job_id, spec, image, profile, inputs):
    identity = ID.get()
    resources = {"cpu": spec.resources.cpu, "memory": spec.resources.memory,
                 "ephemeral-storage": spec.resources.ephemeral_storage}
    cap = profile["quota"]
    concurrency = min(spec.parallelism, cap["pods"], *(
        math.floor(parse_quantity(cap[key]) / parse_quantity(value)) for key, value in resources.items()))
    if concurrency < 1:
        raise ValueError("a single task exceeds the identity quota")
    if spec.resources.gpu:
        if not profile.get("gpu_node") or not cap.get("nvidia.com/gpu"):
            raise ValueError("GPU not enabled for this identity")
        resources["nvidia.com/gpu"] = "1"
        concurrency = min(concurrency, int(cap["nvidia.com/gpu"]))
    task = {"command": spec.command, "args": spec.args, "env": spec.env,
            "working_dir": spec.working_dir, "outputs": spec.outputs, "timeout": spec.timeout,
            "inputs": inputs}
    env = [{"name": "RUNNER_TASK", "value": json.dumps(task)},
           {"name": "JOB_INDEX", "valueFrom": {"fieldRef": {"fieldPath": "metadata.annotations['batch.kubernetes.io/job-completion-index']"}}},
           {"name": "HOME", "value": "/tmp"}, {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"}]
    for index in range(spec.parallelism):
        stem = prefix(job_id) + str(index) + "/"
        transfer = {kind: signed(stem + filename, "put_object") for kind, filename in
                    [("output", "outputs.tar.gz"), ("log", "stdout.log"), ("result", "result.json")]}
        env.append({"name": f"RUNNER_TRANSFER_{index}", "value": json.dumps(transfer)})
    security = {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000,
                "allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                "capabilities": {"drop": ["ALL"]}}
    pod = {"automountServiceAccountToken": False, "enableServiceLinks": False,
           "restartPolicy": "Never", "terminationGracePeriodSeconds": 120,
           "nodeSelector": {"kubernetes.io/arch": "amd64"},
           "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
           "containers": [{"name": "task", "image": image, "command": ["python3", "/opt/vulcan/worker.py"],
                           "env": env, "resources": {"requests": resources, "limits": resources},
                           "securityContext": security, "volumeMounts": [
                               {"name": "work", "mountPath": "/work"}, {"name": "tmp", "mountPath": "/tmp"}]}],
           "volumes": [{"name": "work", "emptyDir": {"sizeLimit": spec.resources.ephemeral_storage}},
                       {"name": "tmp", "emptyDir": {"sizeLimit": spec.resources.ephemeral_storage}}]}
    if SETTINGS.get("image_pull_secret"):
        pod["imagePullSecrets"] = [{"name": SETTINGS["image_pull_secret"]}]
    if spec.resources.gpu:
        pod["runtimeClassName"] = "nvidia"
        pod["nodeSelector"]["kubernetes.io/hostname"] = profile["gpu_node"]
    labels = {OWNER: identity, "app.kubernetes.io/name": "vulcan-task", "kueue.x-k8s.io/queue-name": profile["queue"]}
    labels.update({f"vulcan.olympus/{k}": v for k, v in spec.labels.items() if k != "caller"})
    labels["vulcan.olympus/caller"] = identity
    return {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": job_id, "namespace": NAMESPACE, "labels": labels},
            "spec": {"suspend": True, "completions": spec.parallelism, "parallelism": concurrency,
                     "completionMode": "Indexed", "backoffLimit": 0,
                     "activeDeadlineSeconds": spec.timeout + 300, "ttlSecondsAfterFinished": spec.ttl,
                     "template": {"metadata": {"labels": {OWNER: identity, "app.kubernetes.io/name": "vulcan-task"}}, "spec": pod}}}


def submit_job(spec: JobSpec) -> dict:
    """Submit a suspended Indexed Job; Kueue admits it when this identity has quota."""
    identity, profile = policy()
    if not SETTINGS.get("isolation_verified", False):
        raise PermissionError("submissions disabled: network isolation has not been verified")
    images = list_images()
    alias = spec.image if spec.image in images else next((k for k, v in images.items() if v["image"] == spec.image), None)
    if alias is None:
        raise ValueError("image is not on this identity's allowlist")
    image = images[alias]["image"]
    if not re.fullmatch(r"ghcr\.io/link2427/vulcan-[a-z]+@sha256:[a-f0-9]{64}", image):
        raise ValueError("approved image must have a published immutable digest")
    active = batch.list_namespaced_job(NAMESPACE, label_selector=f"{OWNER}={identity}").items
    if sum(not (j.status.succeeded or j.status.failed) for j in active) >= 128:
        raise ValueError("identity already has 128 unfinished jobs")
    inputs = []
    for uri in spec.inputs:
        expected = f"s3://{BUCKET}/inputs/{identity}/"
        if not uri.startswith(expected) or not re.fullmatch(r"[a-f0-9]{32}\.tar\.gz", uri[len(expected):]):
            raise ValueError("inputs must be uploaded objects belonging to this identity")
        key = uri[len(f"s3://{BUCKET}/"):]
        size = s3.head_object(Bucket=BUCKET, Key=key)["ContentLength"]
        if size > 1024**3:
            raise ValueError("input exceeds 1 GiB")
        inputs.append(signed(key, "get_object"))
    job_id = "vulcan-" + uuid.uuid4().hex
    manifest = job_manifest(job_id, spec, image, profile, inputs)
    record = {"job_id": job_id, "identity": identity, "image": image,
              "resources": spec.resources.model_dump(), "tasks": spec.parallelism,
              "parallelism": manifest["spec"]["parallelism"], "labels": {**spec.labels, "caller": identity},
              "submitted_at": datetime.now(timezone.utc).isoformat(), "state": "submitting"}
    # Record audit before creation; do not record command/env or pre-signed URLs.
    store_json(prefix(job_id) + "submission.json", record)
    LOG.info(json.dumps({"event": "submit_job", **record}))
    try:
        batch.create_namespaced_job(NAMESPACE, manifest)
    except Exception:
        record["state"] = "submission_unknown"
        store_json(prefix(job_id) + "submission.json", record)
        # The API may have committed before a timeout; return its stable ID for inspection.
        return record
    record["state"] = "queued"
    store_json(prefix(job_id) + "submission.json", record)
    return record


def owned_job(job_id):
    prefix(job_id)
    try:
        job = batch.read_namespaced_job(job_id, NAMESPACE)
    except client.ApiException as exc:
        if exc.status == 404:
            raise FileNotFoundError("not found or expired") from None
        raise
    if job.metadata.labels.get(OWNER) != ID.get():
        raise FileNotFoundError("not found or expired")
    return job


def summarize(job):
    conditions = {c.type: c.status for c in job.status.conditions or []}
    state = "queued" if job.spec.suspend else "running"
    if conditions.get("Complete") == "True":
        state = "succeeded"
    elif conditions.get("Failed") == "True":
        state = "failed"
    return {"job_id": job.metadata.name, "state": state, "tasks": job.spec.completions,
            "active": job.status.active or 0, "succeeded": job.status.succeeded or 0,
            "failed": job.status.failed or 0, "completed_indexes": job.status.completed_indexes or "",
            "conditions": [{"type": c.type, "reason": c.reason, "message": c.message} for c in job.status.conditions or []]}


def job_status(job_id: str) -> dict:
    """Current Kubernetes status, or retained final status after Kubernetes TTL cleanup."""
    stem = prefix(job_id)
    record = read_json(stem + "submission.json")
    try:
        status = summarize(owned_job(job_id))
    except FileNotFoundError:
        try:
            status = read_json(stem + "final.json")
        except FileNotFoundError:
            status = {"state": "expired_or_removed", "job_id": job_id}
    status["submitted_at"] = record["submitted_at"]
    status["tasks"] = record["tasks"]
    return status


def list_jobs() -> list[dict]:
    """List only this identity's Kubernetes Jobs. Artifacts outlive Job TTL, up to seven days."""
    identity, _ = policy()
    return [summarize(j) for j in batch.list_namespaced_job(NAMESPACE, label_selector=f"{OWNER}={identity}").items]


def cancel_job(job_id: str) -> dict:
    """Delete this identity's Job and pods, retaining artifacts already uploaded."""
    job = owned_job(job_id)
    final = {**summarize(job), "state": "cancelled"}
    store_json(prefix(job_id) + "final.json", final)
    batch.delete_namespaced_job(job_id, NAMESPACE, propagation_policy="Foreground")
    LOG.info(json.dumps({"event": "cancel_job", "identity": ID.get(), "job_id": job_id}))
    return final


def get_outputs(job_id: str) -> dict:
    """Return per-index signed URLs for output archives, result receipts and persisted logs."""
    stem = prefix(job_id)
    record = read_json(stem + "submission.json")
    files = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=stem):
        for obj in page.get("Contents", []):
            suffix = obj["Key"][len(stem):]
            if re.fullmatch(r"[0-9]+/(outputs.tar.gz|stdout.log|result.json)", suffix):
                files.append({"path": suffix, "size": obj["Size"], "url": signed(obj["Key"], "get_object", True)})
    return {"job_id": job_id, "expected_tasks": record["tasks"], "files": files, "expires_in": 900}


def pod_for_index(job_id, index):
    job = owned_job(job_id)
    if type(index) is not int or not 0 <= index < job.spec.completions:
        raise ValueError("invalid task index")
    pods = core.list_namespaced_pod(NAMESPACE, label_selector=f"batch.kubernetes.io/job-name={job_id}").items
    matches = [p for p in pods if p.metadata.annotations.get("batch.kubernetes.io/job-completion-index") == str(index)]
    if not matches:
        raise FileNotFoundError("task pod has not started or has expired")
    return matches[-1].metadata.name


def job_logs(job_id: str, index: int = 0, tail: int = 200) -> dict:
    """Bounded log tail; REST /logs?follow=true streams live logs. Persisted logs survive pod TTL."""
    if type(index) is not int or not 0 <= index < 128 or type(tail) is not int or not 1 <= tail <= 2000:
        raise ValueError("invalid index or tail (1..2000)")
    stem = prefix(job_id)
    read_json(stem + "submission.json")
    try:
        pod = pod_for_index(job_id, index)
        text = core.read_namespaced_pod_log(pod, NAMESPACE, container="task", tail_lines=tail, limit_bytes=262144)
    except (FileNotFoundError, client.ApiException):
        try:
            text = s3.get_object(Bucket=BUCKET, Key=stem + f"{index}/stdout.log", Range="bytes=-262144")["Body"].read().decode(errors="replace")
        except ClientError:
            return {"job_id": job_id, "index": index, "logs": "", "state": "logs_not_available"}
    return {"job_id": job_id, "index": index, "logs": "\n".join(text.splitlines()[-tail:])}


TOOLS = {fn.__name__: fn for fn in [submit_job, job_status, job_logs, list_jobs, cancel_job, upload_inputs, get_outputs, list_images]}
mcp = FastMCP("Vulcan homelab runner", stateless_http=True, json_response=True, streamable_http_path="/",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=True,
        allowed_hosts=["olympus-vulcan.taild90e78.ts.net", "127.0.0.1:*"],
        allowed_origins=["https://olympus-vulcan.taild90e78.ts.net"]))


def safe_tool(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except (PermissionError, FileNotFoundError, ValueError):
            raise ValueError("request rejected: check identity, ownership, image, paths and resource caps") from None
        except Exception:
            raise RuntimeError("upstream unavailable; inspect job_status before retrying a submission") from None
    return wrapped


for name, fn in TOOLS.items():
    mcp.add_tool(safe_tool(fn), name=name)


class IdentityMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        identity = headers.get(b"x-runner-identity", b"").decode("ascii", errors="ignore")
        token = ID.set(identity)
        try:
            if scope["path"] not in {"/healthz", "/metrics"}:
                try:
                    policy()
                except PermissionError:
                    return await JSONResponse({"error": "Tailscale identity required"}, 401)(scope, receive, send)
                if scope["method"] == "POST":
                    data = bytearray()
                    while True:
                        event = await receive()
                        if event["type"] == "http.disconnect":
                            return
                        data.extend(event.get("body", b""))
                        if len(data) > 1500000:
                            return await JSONResponse({"error": "request too large"}, 413)(scope, receive, send)
                        if not event.get("more_body"):
                            break
                    delivered = False
                    original_receive = receive
                    async def replay():
                        nonlocal delivered
                        if not delivered:
                            delivered = True
                            return {"type": "http.request", "body": bytes(data), "more_body": False}
                        return await original_receive()
                    receive = replay
            await self.app(scope, receive, send)
        finally:
            ID.reset(token)


async def api(request: Request):
    name = request.path_params["tool"]
    if name not in TOOLS:
        return JSONResponse({"error": "unknown tool"}, 404)
    try:
        # Bound the streamed body too; do not trust Content-Length.
        raw = bytearray()
        async for chunk in request.stream():
            raw.extend(chunk)
            if len(raw) > 1500000:
                return JSONResponse({"error": "request too large"}, 413)
        args = json.loads(raw or b"{}")
        if name == "submit_job":
            args = {"spec": JobSpec.model_validate(args["spec"])}
        result = await asyncio.to_thread(TOOLS[name], **args)
        return JSONResponse(result)
    except PermissionError as exc:
        return JSONResponse({"error": str(exc)}, 403)
    except FileNotFoundError as exc:
        return JSONResponse({"error": str(exc)}, 404)
    except (ValueError, TypeError, KeyError):
        return JSONResponse({"error": "invalid input: check schema, allowlist, paths and resource caps"}, 400)
    except Exception:
        # Kubernetes/S3 exceptions can contain URLs or submitted environment values.
        LOG.error("upstream request failed: %s", name)
        return JSONResponse({"error": "upstream unavailable"}, 503)


async def logs(request: Request):
    try:
        job_id = request.path_params["job_id"]
        index = int(request.query_params.get("index", "0"))
        tail = int(request.query_params.get("tail", "200"))
        if not 1 <= tail <= 2000:
            raise ValueError("invalid tail")
        if request.query_params.get("follow") != "true":
            return JSONResponse(await asyncio.to_thread(job_logs, job_id, index, tail))
        pod = await asyncio.to_thread(pod_for_index, job_id, index)
        stream = await asyncio.to_thread(core.read_namespaced_pod_log, pod, NAMESPACE,
            container="task", tail_lines=tail, follow=True, _preload_content=False, _request_timeout=(10, 60))
        def chunks():
            try:
                yield from stream.stream(16384)
            finally:
                stream.close()
                stream.release_conn()
        return StreamingResponse(chunks(), media_type="text/plain")
    except (ValueError, FileNotFoundError, client.ApiException):
        return JSONResponse({"error": "logs unavailable or invalid request"}, 404)


def collect():
    """Persist final status before Job TTL and remove jobs queued >24h (signed URL lifetime)."""
    for job in batch.list_namespaced_job(NAMESPACE, label_selector=OWNER).items:
        token = ID.set(job.metadata.labels[OWNER])
        try:
            summary = summarize(job)
            key = prefix(job.metadata.name) + "final.json"
            if summary["state"] in {"succeeded", "failed"}:
                # Do not rewrite an existing object: lifecycle age must not reset on each sweep.
                try:
                    read_json(key)
                except FileNotFoundError:
                    store_json(key, summary)
            elif job.spec.suspend and (datetime.now(timezone.utc) - job.metadata.creation_timestamp).total_seconds() > 86400:
                store_json(key, {**summary, "state": "queue_timeout"})
                batch.delete_namespaced_job(job.metadata.name, NAMESPACE, propagation_policy="Foreground")
        finally:
            ID.reset(token)


async def janitor():
    while True:
        try:
            await asyncio.to_thread(collect)
        except Exception:
            LOG.error("status collector failed; retrying")
        await asyncio.sleep(30)


def metrics_text():
    jobs = batch.list_namespaced_job(NAMESPACE, label_selector=OWNER).items
    lines = []
    for identity in SETTINGS["profiles"]:
        mine = [j for j in jobs if j.metadata.labels.get(OWNER) == identity]
        lines += [f'vulcan_jobs{{identity="{identity}",state="{state}"}} {sum(summarize(j)["state"] == state for j in mine)}'
                  for state in ["queued", "running", "succeeded", "failed"]]
        lines.append(f'vulcan_active_tasks{{identity="{identity}"}} {sum(j.status.active or 0 for j in mine)}')
        for resource in ["cpu", "memory", "ephemeral-storage", "nvidia.com/gpu"]:
            usage = sum(float(parse_quantity(j.spec.template.spec.containers[0].resources.requests.get(resource, "0"))) * (j.status.active or 0) for j in mine)
            lines.append(f'vulcan_requested_resources{{identity="{identity}",resource="{resource}"}} {usage}')
    return "\n".join(lines) + "\n"


async def metrics(request):
    try:
        return PlainTextResponse(await asyncio.to_thread(metrics_text), media_type="text/plain; version=0.0.4")
    except Exception:
        return PlainTextResponse("upstream unavailable", 503)


@asynccontextmanager
async def lifespan(app):
    global SETTINGS, batch, core, s3, external_s3
    SETTINGS = json.loads(Path(os.environ["RUNNER_CONFIG"]).read_text())
    config.load_incluster_config()
    batch, core = client.BatchV1Api(), client.CoreV1Api()
    s3_config = Config(signature_version="s3v4", s3={"addressing_style": "path"}, retries={"max_attempts": 3}, connect_timeout=10, read_timeout=120)
    options = {"region_name": "us-east-1", "config": s3_config,
               "aws_access_key_id": os.environ["AWS_ACCESS_KEY_ID"], "aws_secret_access_key": os.environ["AWS_SECRET_ACCESS_KEY"]}
    s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"], **options)
    external_s3 = boto3.client("s3", endpoint_url=os.environ["PUBLIC_URL"], **options)
    try:
        s3.head_bucket(Bucket=BUCKET)
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "404":
            raise
        s3.create_bucket(Bucket=BUCKET)
    s3.put_bucket_lifecycle_configuration(Bucket=BUCKET, LifecycleConfiguration={"Rules": [
        {"ID": "seven-day-retention", "Status": "Enabled", "Filter": {"Prefix": ""},
         "Expiration": {"Days": 7}, "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}}]})
    collector = asyncio.create_task(janitor())
    async with mcp.session_manager.run():
        yield
    collector.cancel()
    try:
        await collector
    except asyncio.CancelledError:
        pass


app = IdentityMiddleware(Starlette(lifespan=lifespan, routes=[
    Route("/healthz", lambda request: PlainTextResponse("ok")),
    Route("/metrics", metrics),
    Route("/api/{tool}", api, methods=["POST"]),
    Route("/jobs/{job_id}/logs", logs),
    Mount("/mcp", mcp.streamable_http_app()),
]))
