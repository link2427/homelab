# Olympus GitHub Actions

Flux Kustomization `actions` manages ARC 0.14.2, ephemeral amd64 runners and
BuildKit. It reconciles independently of the aggregate application health gate.
Runner label: `olympus-linux`. Personal accounts require one scale set per
repository; Telchar Dynamics uses the `Olympus trusted` organization group,
which excludes public repositories. GitHub App `olympus-ci-jacob` authenticates
ARC with short-lived installation tokens. Its signing key is SOPS encrypted and
is never mounted in a job pod. The controller watches only `actions-runners`.

## Trust and resource limits

Only trusted private-repository jobs may use this pool. Public repositories and
fork pull requests must remain on GitHub-hosted runners. Do not enable this
pool for repositories that execute unreviewed contributions. All workloads in
this pool share a trust boundary and BuildKit cache; never put credentials in
Docker layers or cache mounts. Use BuildKit secret mounts instead.

The user's runner setup authorization includes the privileged Docker-in-Docker
and BuildKit exception required for existing Docker workflows. No host paths,
host Docker socket, host network or node devices are mounted. Runner pods have
no Kubernetes service-account token. However, privileged containers and plain
Flannel are not a security sandbox: jobs can reach cluster services. A namespace
or unenforced NetworkPolicy does not fix that. Use a separate VM/node security
boundary before accepting untrusted code.

Runners execute on Atlas, with ephemeral job workspaces and Docker daemons.
All pools scale to zero so idle pods do not consume the shared quota while
other repositories have queued jobs. The matching Docker sidecar contains
prebaked container-action tools, avoiding a large copy on each pod startup.
There are at most two runners per scale set; namespace quotas also
bound aggregate CPU, memory and pod consumption. BuildKit permits four parallel
build operations and is limited to eight CPUs and 12 GiB memory. The runner
image includes Node 22, Python 3, Rust 1.98.1, PowerShell 7.6.5, Docker Compose 5.5.1, and common native
build tools, GL/X11/Wayland development libraries and the Tauri Linux SDK.
Node 22 is also preseeded in the setup-node tool cache. Workflows skip native
package installation when these dependencies are already present. Setup actions
can install other SDK versions into disposable job storage. macOS and Windows jobs require compatible runners elsewhere.

## Persistent cache

BuildKit listens only on a ClusterIP and requires a client certificate. Runner
pods receive the client certificate at `/etc/olympus/buildkit`. The server key
is mounted only by BuildKit. Certificates expire September 2027; renew both
certificates and the CA together by replacing the SOPS secret, then restart
BuildKit and idle runners. Do not expose port 1234 through Cloudflare.

The cache uses a dedicated **20 GiB, one-replica SSD** Longhorn PVC. This is an
intentional exception to the normal two-replica SSD class: the bulk node was
offline and remaining SSD scheduling capacity could not fit two replicas at
installation. Cache data is disposable and excluded from backups. The PVC is
retained against accidental Flux pruning. Garbage collection limits retained
data to about 15 GB with a 4 GB free-space target. BuildKit cache mounts may be
pruned after seven days; cache misses must always be safe. Increasing capacity
requires checking Longhorn scheduling and real free disk space first.

Use the shared BuildKit builder for persistent Docker layers and `RUN --mount=type=cache`
package caches. Keep repository-scoped GitHub Actions dependency caches for
non-Docker npm, pip and Cargo jobs; ephemeral runners cannot preserve arbitrary
home-directory files. Cache keys must include OS, toolchain and lockfile hash.

## Verified performance

Two successful Cosmotrak deployments of the same commit on different ephemeral
runners measured the Docker build step at **3m13s cold and 41s warm** (79% faster).
The complete image job fell from 4m42s to 2m04s, excluding queue time. Both runs
passed tests, container smoke checks, image publication and public deployment
verification: [benchmark run, attempts 1 and 2](https://github.com/link2427/Cosmotrak-Website/actions/runs/34004369961).

Preinstalling native libraries reduced AshAndOath's dependency setup from
**7m18s to under one second**; this measures setup, not the entire test suite.
The updated [Linux tests](https://github.com/link2427/AshAndOath/actions/runs/34006243969)
and [performance benchmarks](https://github.com/link2427/AshAndOath/actions/runs/34006243981)
both passed. Actual gains depend on cache hits, workload and cluster contention.

## Recovery and maintenance

The runner image is built by `.github/workflows/runner-image.yml` on a GitHub
hosted runner, so recovery does not depend on ARC. After tool checks pass, it
automatically commits its digest to `runner-defaults.yaml`, which Flux deploys.
Dependabot checks Docker bases and GitHub Actions weekly and opens update PRs.
Merge reviewed updates promptly. Keep the runner version current: GitHub
eventually stops assigning jobs to obsolete versions. Review updates to ARC,
Docker, BuildKit and the image together; do not point production at `latest`.

Inspect `flux get kustomization actions`, HelmReleases in `arc-system` and
`actions-runners`, then listener/runner logs. `kubectl -n actions-runners exec
deploy/buildkit -- buildctl du` reports cache use. For a stuck queue, check
resource-quota events before increasing concurrency. To disable a pool, first
switch its workflows back to GitHub-hosted labels; drain jobs before removing
the scale set. Git reverts restore manifests but do not restore evicted cache.
