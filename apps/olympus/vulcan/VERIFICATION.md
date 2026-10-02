# Vulcan verification — October 1, 2026

This is a review-stage implementation. No Olympus resources, tailnet ACLs,
public routes or existing workloads were changed. Main has not been merged.

## Executed

- [Image CI run 36965681413](https://github.com/link2427/homelab/actions/runs/36965681413)
  passed all checks and all five builds at source commit `1446d47`. Every worker
  passed its real-S3 restricted-container smoke before publication. All images
  are pinned by digest; anonymous GHCR manifest pulls passed for all five.
- Four live Talos/Kubernetes nodes Ready; all 13 existing Flux Kustomizations
  Ready at `0130a147` during initial inspection.
- Confirmed plain Flannel plus kube-proxy; no policy enforcement engine.
- 25 Python checks pass: real MCP initialize/call and REST routes, common image
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
  the user's actual CAD project and live cluster still require the documented tests.

## Live acceptance gates

| Requested check | Status |
| --- | --- |
| Tailnet MCP and REST hello, logs, outputs | Pending reviewed activation and Tailscale enrollment/grants |
| 37-task Indexed CalculiX Job, all outputs and wall time | Pending real Kubernetes run; executable acceptance script provided |
| Outside-tailnet refusal | Pending deployed endpoint and external vantage point |
| Tailnet identity without grant refused | Unit check passes; separate live identity check pending |
| Quota queues excess work; other identity advances | Admission manifest check passes; live two-identity evidence pending |
| Finished Jobs expire | TTL set; live controller expiry check pending |
| Artifacts expire after seven days | Configuration verified; elapsed deletion pending |
| Coder workspace creation | Not applicable: optional tool omitted |

Image publication/build checks are complete. The PR remains a draft for the
activation review. Do not describe pending live checks as demonstrated.
