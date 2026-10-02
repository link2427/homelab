# Vulcan verification - October 2, 2026

Vulcan, Kueue and firewall-only kube-router are merged and deployed through
Flux. The tailnet endpoint is enrolled, HTTPS is enabled, and submissions are
active. State and the 20-GiB artifact volume each have two healthy replicas.

## Executed

- [Image CI run 36965681413](https://github.com/link2427/homelab/actions/runs/36965681413)
  passed all checks and all five builds at source commit `1446d47`. Every worker
  passed its real-S3 restricted-container smoke before publication. All images
  are pinned by digest; anonymous GHCR manifest pulls passed for all five.
- Four live Talos/Kubernetes nodes Ready; all 13 existing Flux Kustomizations
  Ready at `0130a147` during initial inspection.
- Initial inspection found plain Flannel plus kube-proxy. Deployment added
  kube-router v2.11.1 firewall-only on all four nodes. 288 isolation checks
  passed with positive controls; raw sanitized results are in evidence.json.
- 26 Python checks pass (including transient input transport retries): real MCP initialize/call and REST routes, common image
  inventory, missing identity, foreign Job ownership, image/input allowlists,
  resource validation, fail-closed activation gate, tar traversal/link/device
  rejection, bounded expansion, artifact round trip, and Indexed Job structure.
- Go identity check passes: valid grant plus matching subject succeeds; absent
  grant, mismatched identity and tagged device inheriting a user all fail.
- Helm 0.19.2 chart renders 79 resources with the reviewed Kueue values.
- Hardened Python, MuJoCo, Blender and CAE workers each executed successfully with real
  SeaweedFS uploads/downloads, valid archives/receipts, exit code zero, no root,
  no capabilities, read-only root filesystem, resource limits.
- Python hello: task 0.102s, complete container/S3 test 1.36s. MuJoCo: task
  0.368s, complete container/S3 test 0.917s. These are local workstation Docker
  smoke timings, not cluster benchmarks.
- CAE: threaded PARDISO explicitly selected, two threads reported, cube
  displacements checked against the expected range; headless FreeCAD 1.0.0
  created a valid unit box and exported STEP; Gmsh reported 4.13.1. Task 0.221s,
  complete container/S3 smoke 0.906s. A named UID1000 user is required by FreeCAD.
- Blender rendered a 32x32 PNG with CPU Cycles and denoising disabled; task
  0.811s. This Debian build lacks OpenImageDenoiser.
- A 37-completion suspended Indexed Job passed the live Kubernetes API's server
  dry-run validation. No Job or Pod was created by this check.
- 37 independent CAE containers, four concurrent, all passed the complete S3
  input/solve/output path in **10.265 seconds** on the workstation: 37 success
  receipts, 37 valid archives, 37,338 compressed output bytes. Every task checks
  PARDISO's two-thread selection and expected displacement range, plus headless
  FreeCAD and Gmsh. This is **not** a homelab/Kubernetes speed measurement.
  Raw non-secret receipts are committed in [`evidence.json`](evidence.json).
- Seven-day S3 lifecycle configuration round trip passed. Seven-day elapsed
  deletion has **not** been observed.
- [CAD guide](../../../skills/homelab-runner/references/cad-runs.md) JSON validates
  against `JobSpec`; its exact shell command passed for indices 0 and 36 with
  the local cube fixture in restricted, network-disabled CAE containers.
  PARDISO/two-thread output, case mapping, archives' source files and displacement
  range were checked. Documentation links resolve. This is recipe validation;
  the user's actual CAD project still requires its own numerical baseline tests.

## Live acceptance gates

| Requested check | Status |
| --- | --- |
| Tailnet MCP and REST hello, logs, outputs | Passed both transports with rebuilt workers; logs, archive and receipt verified |
| 37-task Indexed CalculiX Job, all outputs and wall time | Passed: indices 0-36, 37 archives and 37 zero-exit receipts; 315.062s from submission to success (includes image pulls) |
| Outside-tailnet refusal | Passed from GitHub-hosted runner, CI 36969165601 |
| Tailnet identity without grant refused | Live ephemeral tag:runner client received HTTP 403 |
| Quota queues excess work; other identity advances | Passed: Norma completed while Jacob saturated and a second Jacob Job queued; cancellation released the queued Job |
| Finished Jobs expire | Passed: both 300-second hello Jobs deleted; stored outputs still retrievable |
| Artifacts expire after seven days | Configuration verified; elapsed deletion pending |
| Coder workspace creation | Not applicable: optional tool omitted |

Live identity checks also confirmed that Jacob cannot inspect Norma's Job (HTTP
404, deliberately hiding foreign identifiers). The temporary client used
in-memory ephemeral Tailscale state, then the existing runner-norma profile.

The first live CAE batch exposed transient connection refusal immediately after
pod startup; diagnostic tasks succeeded on the same path two seconds later.
PR #35 adds bounded input-download retries without changing HTTP authorization
failures or download-size limits. All rebuilt images passed CI 36969281700,
including real-S3 restricted-container checks. PR #36 pins those digests.
The repeat live Indexed Job completed all 37 tasks without failures. Its total
time includes deployment image pulls, including 4m25.761s on precision-7810-01.

Final live acceptance ran against Flux revision `723598d`, image CI
[36969281700](https://github.com/link2427/homelab/actions/runs/36969281700).
The 37 cases repeat the small uploaded cube fixture; they are not 37 distinct
CAD designs. All archives contain nonempty cube.dat/cube.frd and correct index
markers. The cold-image run is not a steady-state throughput benchmark.

Seven-day expiry must be observed after October 9, 2026, plus the store sweep
interval. Baseline Job IDs are retained under `live_acceptance` in evidence.json.
The original empty 40-GiB artifact claim remains detached and prune-protected;
the active 20-GiB claim and 1-GiB state claim are healthy with two replicas each.
Temporary isolation/prewarm pods and the ephemeral identity client were stopped.
The actual CAD project's numerical baseline/integration is a separate client
workflow, described in the copyable CAD calling prompt.
