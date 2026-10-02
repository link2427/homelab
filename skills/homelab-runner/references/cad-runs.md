# CAD and CAE runs on Vulcan

## Availability and prerequisites

Vulcan is deployed through Flux as of October 2, 2026. Network enforcement and
Tailscale enrollment are active. Check the [verification record](https://github.com/link2427/homelab/blob/main/apps/olympus/vulcan/VERIFICATION.md)
for completed live tests and remaining checks. Deployment is handled separately
from CAD project integration.

Use a granted tailnet host and the REST/MCP setup in
[SKILL.md](../SKILL.md). A cloud agent needs an actual tailnet-connected execution
environment. Keep interactive CAD editing and inspection on the workstation or
in Coder; send independent geometry, mesh, solve or render tasks to Vulcan.

## What runs where

| Work | Image / entry point | Boundary |
| --- | --- | --- |
| Headless FreeCAD geometry/export | `cae`, `freecadcmd script.py` | Uses FreeCAD's embedded Python; ordinary `python3` is a separate interpreter |
| Meshing | `cae`, `gmsh` CLI | Verify the project's mesh options and output format |
| FEM solve | `cae`, `ccx -i model` | Select PARDISO in the input deck; check solver/thread messages and convergence |
| CadQuery or project-specific Python CAD | Approved project image | CadQuery and arbitrary project dependencies are not installed in the initial CAE image |
| Physics | `mujoco` | Match model/assets and verify the project's numerical results |
| Render | `blender` | CPU Cycles; disable denoising for this Debian build |

Call `list_images` and record the returned digest before each reproducibility
run. Missing dependencies belong in a reviewed CI-built image using the existing
image-addition procedure. Task pods cannot download packages. No project source,
CAD model or input data is baked into the public standard images.

## Prepare a real project run

Use the project's existing command and validation logic. Record its commit,
parameter/case mapping, seeds, units, material definitions, solver settings,
image digest and SHA-256 of the input archive. Include uncommitted input files
explicitly if needed; a Git commit alone does not identify them.

Start with one representative case. Run it locally with the same image and
resource/thread settings to establish expected geometry/mesh/solver results.
Then send the same input to Vulcan. Fix compatibility and result differences
before attempting a sweep. Native workstation results can be an additional
baseline, with differing software versions recorded.

Package only scripts, inputs and needed assets into a tar archive with relative
paths and regular files/directories. Exclude credentials, `.git`, virtualenvs,
caches and prior outputs. Maximum per tar: 1 GiB compressed, 4 GiB expanded,
10,000 entries. `upload_inputs` returns a scoped PUT URL and an input URI; upload
the exact declared bytes, then put that URI in `submit_job.spec.inputs`.
Signed URLs expire after 15 minutes and do not belong in saved reports.

## Indexed CalculiX example

For a solve-only sweep, this archive layout keeps includes beside each deck:

```text
cases/000/model.inp
cases/000/materials.inc
cases/001/model.inp
...
cases/036/model.inp
```

Every index gets a separate `/work` with the same archive. `JOB_INDEX` selects
the case; it does not divide one solver invocation across nodes. The following
tool arguments assume each deck requests the `.dat` and `.frd` outputs and uses
PARDISO. Replace the input URI and project label, and size resources/deadline
from the single-case measurement.

```json
{
  "spec": {
    "image": "cae",
    "command": ["sh", "-ec"],
    "args": ["case_dir=$(printf 'cases/%03d' \"$JOB_INDEX\"); cd \"$case_dir\"; ccx -i model; test -s model.dat; test -s model.frd; mkdir -p /work/results; cp model.dat model.frd /work/results/; printf '%s' \"$JOB_INDEX\" > /work/results/index.txt"],
    "env": {
      "OMP_NUM_THREADS": "2",
      "MKL_NUM_THREADS": "2",
      "CCX_NPROC_EQUATION_SOLVER": "2",
      "CCX_NPROC_RESULTS": "2",
      "NUMBER_OF_CPUS": "2"
    },
    "working_dir": ".",
    "resources": {"cpu": "2", "memory": "2Gi", "ephemeral_storage": "8Gi"},
    "parallelism": 37,
    "inputs": ["s3://vulcan/inputs/<identity>/<upload-id>.tar.gz"],
    "outputs": ["results"],
    "timeout": 3600,
    "ttl": 86400,
    "labels": {"project": "cad-validation", "purpose": "case-sweep"}
  }
}
```

For a full geometry-to-solve run, replace that command with the project's
headless pipeline. Keep its FreeCAD invocation under `freecadcmd`, invoke Gmsh
and CalculiX as appropriate, and collect geometry, mesh and validation summaries
under `results`. There is no shared writable workspace across tasks. Download
results and reduce locally, or upload the collected results to a second job.

## Capacity, deadlines and failure behavior

- Resources are **per task**. With the example's 2 CPU/2 GiB/8 GiB requests,
  current caps allow at most 16 concurrent tasks for Jacob or four for Norma.
  Kueue may queue the whole job while that profile's reservation is occupied.
  More threads inside a container do not raise its CPU limit.
- `parallelism` means total tasks (1–128). Estimate the number of waves from
  the admitted concurrency, then measure cold image pulls, input transfers,
  computation and output collection. Do not promise faster single-case solves.
- **Current timeout behavior:** each command has the submitted `timeout`, and
  the entire admitted Kubernetes Job has `activeDeadlineSeconds=timeout+300`.
  That job deadline covers **all waves**, not a fresh deadline per wave. Size
  `timeout` for the whole batch plus headroom, or split long runs into smaller
  submissions. Maximum submitted timeout is 86,400 seconds; queue wait is
  capped separately at 24 hours. The five-minute difference is not a per-task
  upload guarantee when the batch consumes the deadline.
- `/work` and `/tmp` are ephemeral and share the pod's storage budget. Leave
  room for expanded inputs, solver scratch and output compression. Declared
  outputs are relative to `/work`, even after the command changes directories.
  Output limit is 2 GiB uncompressed/10,000 entries per task; saved logs are
  capped at 20 MiB. The initial shared artifact store is only 20 GiB.
- There are no automatic solver retries (`backoffLimit=0`). A failed index can
  fail the whole Job and terminate other tasks; inspect receipts and logs before
  rerunning a bounded set of cases. Cancellation, OOM or node loss can leave
  partial or absent artifacts. A missing receipt is never a successful solve.

## Validate and preserve the results

Poll `job_status`, read `job_logs`, then use `get_outputs`. Save each index's
archive, log and receipt under a distinct local case directory before extracting
with a safe archive extractor. Require all expected indices, exit code zero and
`outputs_uploaded=true`. Never overwrite one case with another's `results/`.

Validate results with the project's existing checks and tolerances chosen before
the comparison: valid geometry and expected dimensions/volume; nonempty usable
mesh and element counts; solver convergence, finite displacement/stress values
and expected load/reaction behavior. File existence and process exit alone do
not establish engineering correctness. Compare numerical values with suitable
tolerances rather than requiring byte-identical solver files.

Keep a small project-owned run record: project revision and input hash, case-ID
mapping, image digest, resource/thread settings, job ID, per-index receipt and
validation outcome, queue/compute/total elapsed times when observable, and
failed/missing cases. Separate cold and warm runs. Keep CAD files and detailed
results in the project; use sanitized summaries in the public homelab PR.

Artifacts expire seven days after their last write; Job objects default to a
one-day TTL. Save wanted outputs to durable project storage before retention.
If `get_outputs` URLs expire, request fresh URLs; do not resubmit a successful
compute job just to download it again.

## Real CAD acceptance checklist

1. Check the live acceptance record and call `list_images` from the intended
   client. Local Docker timings are not cluster performance evidence.
2. Identify the actual CAD repository, representative command and expected
   outputs. If these are not known, ask for their location instead of inventing
   a project. Check dependencies against the approved image.
3. Pass one real case locally and through REST, then through MCP using the same
   input archive. Compare artifacts, numerical checks and logs.
4. Pass a small multi-case sweep, then 37 mapped cases where available. If fewer
   distinct cases exist, label repetitions as a throughput test, not 37 designs.
   Collect every index and report end-to-end wall time and concurrency.
5. Exercise queue contention with the two granted identities, an ungranted
   identity, outside-tailnet access, cancellation and short Job TTL. Preserve
   baseline object IDs for the later seven-day deletion observation; do not mark
   elapsed cleanup complete from lifecycle configuration alone.
6. Copy the entire `homelab-runner` skill folder, including this reference, into
   the selected CAD repository's `.agents/skills/`; configure that caller's MCP
   connection and document the tested command/results in its own docs. Update
   the homelab runbook, verification record and local operational context with
   actual deployed commits, outcomes and remaining limitations.

## Copyable calling prompt

```text
Integrate my CAD runs with the Olympus Vulcan compute runner. Deployment is handled separately; focus on calling jobs and testing my CAD workflow.

Read D:/repos/homelab-runner/skills/homelab-runner/SKILL.md and references/cad-runs.md. Copy the entire skill folder into the CAD project's .agents/skills/homelab-runner/.

MCP: https://olympus-vulcan.taild90e78.ts.net/mcp/
On a granted tailnet machine:
claude mcp add --transport http --scope user homelab-runner https://olympus-vulcan.taild90e78.ts.net/mcp/
Authentication uses Tailscale identity; no API key.

Call list_images. Package relative-path inputs as tar.gz, call upload_inputs(size=<bytes>), and PUT bytes with the returned URL/headers. Pass the returned input URI to submit_job(spec={image,command,inputs,outputs,resources,parallelism,timeout}). Resources are per task; parallelism is total tasks, each with JOB_INDEX starting at zero. Quotas cap simultaneous execution.

Poll job_status(job_id), inspect job_logs(job_id,index), and call get_outputs(job_id). Download every index's outputs.tar.gz and result.json; check all indices, exit_code=0, outputs_uploaded=true and engineering tolerances. cancel_job stops work; save wanted artifacts before seven-day expiry. REST is POST /api/<tool> on the same hostname with the same JSON arguments.

Prepare one real local CAD baseline, run the matching remote case through REST and MCP, then an indexed sweep. Compare numerical results and record timings. CAE includes FreeCAD, Gmsh and CalculiX/PARDISO, NOT CadQuery. No runtime Internet/package installation. The whole-Job deadline is timeout+300 seconds across all waves; split long sweeps as needed.

If connectivity is temporarily unavailable, continue packaging, adapters and local baseline tests and report the precise failure. Do not take over deployment. Document the CAD project's submission, monitoring, artifact retrieval and tested results.
```
