---
name: homelab-runner
description: Run containerized batch work on Olympus through Vulcan: submit independent jobs or indexed fan-out, read logs, cancel, and fetch artifacts. Use for CAE solves, MuJoCo, CPU renders, tests, and data processing when the caller has tailnet access.
---

# Homelab runner

Endpoint: `https://olympus-vulcan.taild90e78.ts.net`. MCP: `/mcp/`.
The calling machine must be on Jacob's tailnet and have a runner grant. Cloud
agents need a tailnet-connected execution environment or an approved local MCP
bridge. A normal cloud HTTP connector cannot reach this private endpoint.
Never enable Funnel or a public tunnel to make a client connect.

Authenticate through the machine's existing Tailscale connection; no API token.
Use `list_images` first. Images are administrator-approved immutable digests;
aliases initially include `python`, `cae`, `mujoco`, `blender`.

## Submit and retrieve

1. Put inputs into a `.tar.gz` containing only regular files/directories with
   relative paths. No links or `..`. Maximum compressed size 1 GiB, expansion
   4 GiB per tar, 10,000 entries. Do not include credentials.
2. Call `upload_inputs(size=<exact bytes>)`; PUT the bytes to the returned URL
   with its returned headers, then pass its `input` URI into `submit_job`.
   For <=1 MiB, `payload_base64` can upload directly. URLs expire in 15 minutes;
   treat them as temporary capabilities and omit them from logs/transcripts.
3. Submit using the following tool arguments. All resource values are per task.
   `parallelism` is the total task count. The runner caps concurrent tasks at
   the identity's resource budget; Kueue queues work when the budget is busy.

```json
{
  "spec": {
    "image": "cae",
    "command": ["sh", "-ec"],
    "args": ["mkdir -p results; ccx -i cube; cp cube.dat cube.frd results/; printf '%s' \"$JOB_INDEX\" > results/index.txt"],
    "env": {"OMP_NUM_THREADS": "2", "MKL_NUM_THREADS": "2", "CCX_NPROC_EQUATION_SOLVER": "2"},
    "working_dir": ".",
    "resources": {"cpu": "2", "memory": "2Gi", "ephemeral_storage": "8Gi"},
    "parallelism": 37,
    "inputs": ["s3://vulcan/inputs/<identity>/<upload-id>.tar.gz"],
    "outputs": ["results"],
    "timeout": 600,
    "ttl": 86400,
    "labels": {"project": "norma", "purpose": "mesh-sweep"}
  }
}
```

Each task has its own `/work`, starts with the same uploaded inputs, and sees
`JOB_INDEX=0..36`. Select that index's case inside the command. Workdir and output
paths are relative to `/work`. Root filesystem is read-only; `/work` and `/tmp`
are writable. Keep outputs under 2 GiB per task. The service owns the caller
label and queue; clients cannot choose either. Up to 128 tasks per submission.

4. Save the returned `job_id`. Poll `job_status(job_id)` every few seconds,
   backing off during a long queue wait. A queued Job has not begun computing.
   A single task larger than the total identity budget is rejected; several
   jobs that together exceed the budget queue. Queue wait is capped at 24 hours.
5. Read `job_logs(job_id, index=0, tail=200)` for bounded logs. Streaming is
   available at `GET /jobs/<job-id>/logs?index=0&follow=true` (reconnect if idle).
   MCP log calls return bounded snapshots. Saved logs are capped at 20 MiB/task.
6. Call `get_outputs(job_id)`. Download each index's `outputs.tar.gz` and
   `result.json`; check every receipt's exit code and `outputs_uploaded`.
   Success requires all expected indices. A failed/terminated/OOM task may have
   incomplete or absent artifacts. Do not assume a missing result means success.

`list_jobs` lists your live Kubernetes Jobs. `cancel_job` cancels only your Job;
already uploaded outputs remain. Artifacts expire seven days after each object
was written; Kubernetes Jobs default to 24 hours after completion. Save wanted
results elsewhere before retention. Failed/timeout submissions must be inspected
with `list_jobs` before retrying to avoid duplicate work.

Jobs have no Internet/package-install egress. Bake dependencies into an approved
image. Optional `resources.gpu=1` is allowed only for an identity configured for
an exact GPU node; the standard render images use CPU. Don't put secrets in
command, args, env, labels, or inputs; there is no inline secret facility.

## REST equivalent

REST uses `POST /api/<tool-name>` with the same JSON arguments as MCP:

```sh
RUNNER=https://olympus-vulcan.taild90e78.ts.net
curl --fail "$RUNNER/api/list_images" -H 'Content-Type: application/json' -d '{}'
curl --fail "$RUNNER/api/submit_job" -H 'Content-Type: application/json' \
  -d '{"spec":{"image":"python","command":["python3","-c","print(42)"],"parallelism":1}}'
curl --fail "$RUNNER/api/job_status" -H 'Content-Type: application/json' \
  -d '{"job_id":"<returned-job-id>"}'
```

## MCP setup

On a granted, tailnet-connected Claude Code host:

```sh
claude mcp add --transport http --scope user homelab-runner https://olympus-vulcan.taild90e78.ts.net/mcp/
```

Codex `config.toml`:

```toml
[mcp_servers.homelab-runner]
url = "https://olympus-vulcan.taild90e78.ts.net/mcp/"
```

This folder can be copied unchanged to Norma's `.agents/skills/homelab-runner/`.
Keep Coder for interactive debugging; this service does not create workspaces.
