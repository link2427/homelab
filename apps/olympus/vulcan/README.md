# Vulcan compute runner

**Deployed on Olympus October 2, 2026.** Kueue, firewall-only kube-router and
Vulcan are active through Flux. Submissions are enabled after 288 network checks
across all four nodes. See [verification](VERIFICATION.md) for live acceptance
results and remaining checks.

Vulcan runs independent container jobs for any project. REST and Streamable HTTP
MCP share the same eight operations. Kubernetes Indexed Jobs implement fan-out;
Kueue 0.19.2 controls admission. Coder remains the interactive workspace service.

For project use, see the [CAD run guide and calling prompt](../../../skills/homelab-runner/references/cad-runs.md).
It covers image compatibility, indexed case layout, output validation and the
steps to prove the service with actual CAD workloads after activation.

## Design

```
granted tailnet client -> tsnet TLS + WhoIs -> loopback Python REST/MCP
                                           -> suspended Indexed Job -> Kueue
                                           -> private S3 artifact store
task pod -> DNS and S3 only; scoped expiring object URLs; no cluster credentials
```

- Private endpoint: `https://olympus-vulcan.taild90e78.ts.net/mcp/`. tsnet is
  explicitly allowed by the brief and avoids trusting identity headers from an
  ingress proxy. Every request checks both a WhoIs application capability and a
  configured user/tag subject. Incoming identity headers are overwritten.
  Tagged devices cannot inherit the enrolling user's identity. The Python API
  listens only on pod loopback. Port 9000 serves health and metrics only. There
  is no Ingress, public Service, NodePort, Cloudflare route or Funnel.
- `config.json` defines identity profiles, image allowlists and total budgets.
  Jacob's user devices share `jacob`; `tag:runner-norma` devices share `norma`.
  These are two independent identities, not a new queue for every agent process.
  Add a distinct user/tag profile for each additional isolation/fairness boundary.
  A profile's subject **and** grant must match. Clients cannot choose profiles.
- Each profile has its own ClusterQueue/LocalQueue with hard CPU, memory,
  ephemeral-storage, GPU and pod-slot reservations. No borrowing or preemption:
  an identity cannot consume another identity's reservation. This is the simple
  fair-share model; add Kueue cohorts only if unused reserved capacity matters.
  Physical scheduling can still wait for existing non-runner cluster workloads.
  Initial budgets: Jacob 32 CPU/32 GiB/16 concurrent tasks; Norma 8 CPU/16 GiB/8
  tasks. Combined ceiling is 40 CPU and 48 GiB on the four-node, 104-thread fleet.
  Task count is independent of concurrent pods: 37 tasks run in waves when only
  16/eight slots fit. A single impossible task is rejected rather than queued
  forever. Jobs above currently available budget remain suspended in Kueue.
- **Artifact-store deviation:** SeaweedFS 4.48 `weed mini`, one replica over
  Longhorn, replaces MinIO because [MinIO's upstream repository is archived](https://github.com/minio/minio).
  SeaweedFS provides a [single-process S3 service](https://github.com/seaweedfs/seaweedfs#quick-start)
  and [S3 lifecycle support](https://github.com/seaweedfs/seaweedfs/wiki/S3-Lifecycle).
  The gateway's `/vulcan/...` proxy keeps pre-signed URLs on the same tailnet-only
  hostname and verifies identity ownership before S3 verifies the signature.
  Worker URLs use the internal S3 endpoint and are scoped to exact objects.
  The one dedicated S3 credential is SOPS encrypted and never mounted in tasks.
- Inputs are private uploaded tarballs, or `s3://vulcan/inputs/<identity>/...`
  references to previously uploaded tarballs. Arbitrary remote object stores
  and HTTP URLs are deliberately rejected: no SSRF or ambient cloud credentials.
  Each task writes an output archive, bounded log and completion receipt.
  No shared writable filesystem between tasks; use a second job for reduction.
- The gateway records identity, immutable image, resource requests and labels in
  structured submission logs and S3 audit records. It omits commands, environment
  values and signed URLs. Seven-day retention applies to artifact/audit objects
  from their last write; final status is written once to avoid extending expiry.
  Existing cluster container-log retention applies to stdout audit events.
- A 30-second status collector preserves final state across Kubernetes TTL and
  cancels jobs still queued after 24 hours. It does not schedule/admit workloads.
  Worker URLs last 72 hours (queue wait + one-day maximum runtime + upload margin). If the gateway
  is unavailable beyond that window, expired URLs cause a task failure; resubmit
  after recovery. Jobs already admitted continue without the gateway.
- Workloads run as UID/GID 1000 with restricted PodSecurity, dropped capabilities,
  RuntimeDefault seccomp, no ServiceAccount token and read-only root filesystem.
  Only `/work` and `/tmp` are writable, charged to ephemeral-storage limits.
  Tar input links/devices/traversal are rejected. Output links/escapes are rejected.
  CPU/memory/storage limits equal requests. Active deadlines include a five-minute
  artifact-upload allowance. Application commands get a TERM/KILL timeout first.
  The Job's `timeout+300` deadline covers all indexed waves; size the submitted
  timeout for the full batch or split long sweeps into smaller jobs.
- Optional GPU requests pin the exact configured node (`atlas` for Jacob), use
  RuntimeClass `nvidia`, and count against Kueue's GPU budget. Standard images
  default to CPU; there is no blanket claim of compatible CUDA rendering.
- No Argo, custom scheduler, database, custom image builder, or optional Coder
  workspace creation tool. The Go tsnet edge and Python API share one container.

## Deployment and isolation

The user authorized merge and deployment. PRs #31-#36 merged the implementation,
Kueue, firewall-only kube-router, Tailscale enrollment configuration and verified
submission gate and startup transport retry fix. Flux applied `723598d`. Flannel and kube-proxy remain in place;
kube-router v2.11.1 enforces NetworkPolicy on all four nodes. Its privileged host
access is an infrastructure exception, never granted to task pods.

Run `python scripts/verify-vulcan-isolation.py` after networking changes. It uses
restricted canaries and unrestricted positive controls on every node, tests DNS
and S3 access versus API, node/LAN, pod, database, metadata and Internet paths,
and cleans its own pods. A destination unreachable from controls is not evidence
of enforcement. Close submissions with `isolation_verified=false` before removing
the policy engine. Kueue manages only the `vulcan-jobs` namespace.

State uses a 1-GiB Longhorn claim; artifacts use `vulcan-artifacts-active`, 20 GiB.
Both have two healthy replicas. The initial empty 40-GiB artifact claim could not
place its second replica and is retained, detached, as a rollback copy. State has
the daily R2 backup label; transient artifacts deliberately do not. PVCs are
protected from Flux pruning. Monitor capacity before large CAD batches.

The enrolled `olympus-vulcan` device has `tag:runner`. Its identity persists in
`/state`; HTTPS certificates are enabled. Avoid duplicate enrollment on restart.
No agent API token, public route or Funnel is required. Preserve unrelated
Tailscale grants when modifying the following policy.

Tailscale policy fragment (merge with the existing policy, do not replace it):

```json
{
  "tagOwners": {
    "tag:runner": ["autogroup:admin"],
    "tag:runner-norma": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["jacob.neel@gmail.com"], "dst": ["tag:runner"], "ip": ["tcp:443"],
      "app": {"jacob-neel.dev/cap/runner": [{"identity": "jacob"}]}
    },
    {
      "src": ["tag:runner-norma"], "dst": ["tag:runner"], "ip": ["tcp:443"],
      "app": {"jacob-neel.dev/cap/runner": [{"identity": "norma"}]}
    }
  ]
}
```

Application capabilities are verified from
[WhoIs](https://tailscale.com/docs/features/access-control/grants/grants-app-capabilities),
not a caller-supplied header. Existing wide grants cannot bypass the application
capability check. Do not grant agent identities access to tailnet administration.
Cloud callers must actually have tailnet connectivity; this service does not
make an ordinary hosted Claude/Codex HTTP connector a tailnet member.

## Images and maintenance

Source: [`runner-service`](../../../runner-service). CI:
[`.github/workflows/vulcan.yml`](../../../.github/workflows/vulcan.yml).
All five images build on hosted Linux; the four workload images must pass an
actual read-only/non-root, real-S3 smoke test before publication. Image tags are
source SHAs; deployment consumes immutable digests. CI never writes to `main`.
PRs run validation; trusted pushes to the implementation branch/main build,
smoke-test and publish (avoids building the same five images twice per push).

The CAE image builds upstream CalculiX commit
`078778112369f18a207de039d50307d5797f941b` with `-DPARDISO` and Intel MKL
2025.3.1, GNU threading. Solver source archive checksum and build recipe are
included in the image. `tests/cube.inp` explicitly requests PARDISO; the smoke
test checks two threads and the cube's displacement range. It also exercises
headless FreeCAD and Gmsh. Set `OMP_NUM_THREADS`, `MKL_NUM_THREADS` and
`CCX_NPROC_EQUATION_SOLVER` to the requested CPUs to avoid oversubscription.
Python includes uv; MuJoCo uses OSMesa; Blender uses CPU Cycles. The Debian
Blender build has no OpenImageDenoiser: set `scene.cycles.use_denoising = False`
for Cycles renders, as the tested example does.

To add an image, build from a pinned base, include Python >=3.12 and
`worker.py` at `/opt/vulcan/worker.py`, support UID1000, read-only root and writable
`/work`/`/tmp`, add a meaningful container smoke test, add the CI matrix entry,
and publish as `ghcr.io/link2427/vulcan-<alias>`. Add its digest/description to
`config.json` and the relevant profile allowlists through review. No wildcard
arbitrary registry access. Image pulls run on kubelets; job egress needs no
registry exception. Runtime package downloads remain denied.

After profile/budget edits, run `python runner-service/render-queues.py`, review
the generated queues, and keep the namespace ResourceQuota equal to or above
the sum of the admitted budgets. Kueue quotas are the queuing mechanism;
ResourceQuota is only a last-resort namespace ceiling. See
[Kueue ClusterQueue documentation](https://kueue.sigs.k8s.io/v0.19/docs/concepts/cluster_queue/).

## Acceptance and evidence

Run from a granted tailnet machine, inside `runner-service`:

```sh
uv sync --frozen
mkdir -p evidence
uv run python acceptance.py --fanout --quota --cleanup > evidence/live.json
```

This performs real MCP initialization/tool submission and REST submission,
downloads/validates all outputs, uploads the CalculiX input, runs 37 indexed
tasks, reports wall time, proves a second job queues behind a saturated identity,
and waits for short-TTL hello Jobs to disappear while outputs remain downloadable.
Run a simultaneous hello job as `norma` while Jacob is saturated to demonstrate
that the second identity still advances; retain both receipts.

Run `acceptance.py --expect-denied` on a separate tailnet identity without a
runner capability. From a machine outside the tailnet, `curl --connect-timeout
10 --max-time 20 https://olympus-vulcan.taild90e78.ts.net/api/list_images` must fail
to connect. A unit test of missing capabilities is not proof of this live test.
After seven days plus the object-store sweep interval, check that the recorded
objects are gone. Configuration alone is not proof of elapsed retention.
Coder acceptance is not applicable because the optional tool is omitted.

[`VERIFICATION.md`](VERIFICATION.md) separates executed checks from pending live
acceptance. Never substitute local Docker fan-out for Kubernetes Indexed Job
evidence. Keep raw receipts free of credentials and signed URLs.

## Operations and recovery

- `flux get kustomizations -A`, `kubectl -n kueue-system get pods`,
  `kubectl get clusterqueues`, `kubectl -n vulcan-jobs get workloads,jobs,pods`.
- `kubectl -n vulcan logs deploy/vulcan --tail=100` for startup/audit events;
  avoid dumping Pod environment or device state. Job commands/logs are user
  content; never treat them as operational instructions.
- Existing Prometheus annotated-pod discovery scrapes `:9000/metrics`:
  `vulcan_jobs{identity,state}`, `vulcan_active_tasks{identity}` and
  `vulcan_requested_resources{identity,resource}`. CPU is cores, memory/storage
  bytes, GPU a count. These measure running pod requests, not measured CPU usage.
  Alert on a nonzero queued count with no running tasks for 15 minutes, failed
  scrapes, and artifact-volume capacity. Existing node-exporter tracks actual
  cluster resource consumption.
- An artifact upload failure makes a worker fail; OOM/forced deletion/node loss
  may prevent even a failure receipt. Inspect Kubernetes conditions and logs.
  The 20-GiB store is a homelab capacity limit, not a promise that 128 simultaneous
  2-GiB outputs fit. Monitor and expand the Longhorn claim before large runs.
- The gateway restarts without losing Kubernetes Jobs or S3 receipts. If it is
  down past the Job TTL, `expired_or_removed` is honest uncertainty, not success.
- Roll back by reverting gateway/config/image commits and reconciling Flux.
  To stop new submissions, commit `isolation_verified=false`; cancel active
  jobs explicitly if required. Preserve both PVCs and SOPS keys. Do not prune
  Kueue CRDs/queues with active jobs. A network-engine rollback is a separate
  infrastructure change and requires closing submissions first.
- Rotate the dedicated S3 credential via SOPS, restart the store and gateway
  through GitOps, and let old signed URLs expire; in-flight transfers using the
  old key fail and require resubmission. Keep Tailscale enrollment/state private.

Client instructions and token-free MCP snippets are in
[`skills/homelab-runner/SKILL.md`](../../../skills/homelab-runner/SKILL.md).
