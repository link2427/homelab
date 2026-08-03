# Olympus homelab handbook

This handbook records the Olympus cluster as it exists on August 2, 2026. It
is the operational companion to the manifests in this repository: Git remains
the source of truth, while this document explains the hardware, design choices,
access paths, recovery model, and the work completed during the current rebuild.

## At a glance

- Kubernetes cluster: `my-cluster` (operational name: **Olympus**)
- Operating system: Talos Linux `v1.12.6`
- Kubernetes: `v1.35.2`
- GitOps: Flux `v2.9.3`, watching `main` in `link2427/homelab`
- CNI: Flannel
- Primary remote network: Tailscale
- Public application ingress: Cloudflare Tunnel
- Distributed storage: Longhorn `v1.12.0`
- Distributed image cache: Spegel `v0.7.4`
- NAS storage and backups: Atlas at `10.0.0.5`
- Cluster console: Headlamp
- Development platform: Coder `v2.35.3`
- Identity provider: Authentik `2026.5.6`

The active cluster has three x86-64 nodes. The former Raspberry Pi nodes are
powered off and are not part of the active compute fleet.

## Physical and network inventory

| System | Address | Role | Capacity | Accelerator | Longhorn role |
| --- | --- | --- | --- | --- | --- |
| `optiplex-hermes` | `10.0.0.57` | control plane + etcd + worker | 12 CPU threads, 16 GiB RAM, ~473 GiB NVMe | none | `fast`, `nvme`, `storage`; 200 GiB reserved |
| `precision-5810-01` | `10.0.0.25` | worker | 12 CPU threads, 16 GiB RAM, ~231 GiB SSD | Quadro M4000, 8 GiB | `fast`, `ssd`, `storage`; 80 GiB reserved |
| `precision-7810-01` | `10.0.0.171` | worker | 8 CPU threads, 32 GiB RAM, ~1.86 TiB HDD | Quadro P2000, 5 GiB | `bulk`, `hdd`, `storage`; 300 GiB reserved |
| Atlas | `10.0.0.5` | NAS, media, NFS, backup target | `DATA-1`, `DATA-2` | none | NFS and Longhorn backups |
| HP 2920 | `10.0.0.95` | rack switch | managed Ethernet | none | n/a |
| Gateway | `10.0.0.1` | LAN router and DHCP | n/a | none | n/a |

Both Precision workstations were converted from Windows to Talos. They boot in
UEFI mode from their internal system disk, and the reusable Talos installer USB
was removed after each installation. A GPU or monitor is not required for
headless operation.

### Control-plane availability

`optiplex-hermes` is currently the only control-plane and etcd member visible
to Kubernetes. The Precision systems add compute, storage, and GPUs, but they do
not currently provide control-plane redundancy. Losing or powering off the
OptiPlex stops the Kubernetes API and scheduling even though existing containers
may continue running for a time.

A future high-availability conversion should use three control-plane members,
preferably the OptiPlex and both Precision systems, and must verify etcd health
before any old member is removed.

## Cluster architecture

```text
GitHub main branch
       |
       v
Flux source-controller
       |
       +--> flux-system
       +--> infrastructure
       |      +-- namespaces, metrics-server, NFS provisioners
       |      +-- Tailscale operator, NVIDIA device plugin
       |      `-- Longhorn, storage classes, and Spegel image cache
       `--> apps
              +-- Homepage, Headlamp, Coder
              +-- Grafana, Prometheus, Uptime Kuma
              +-- Pi-hole, n8n, Portainer
              `-- Telchar Construct and Telchar Forge
```

Reconciliation is ordered in
[`clusters/olympus`](../clusters/olympus): `flux-system` → `infrastructure` →
`apps`. SOPS decrypts secret-bearing manifests inside the cluster. The age
private key is never committed; it is stored at
`C:\Users\Jacob\.config\sops\age\keys.txt` and in the
`flux-system/sops-age` Secret.

## Storage design

Olympus deliberately has two storage planes.

### Longhorn local distributed storage

| StorageClass | Replicas | Placement | Intended use |
| --- | ---: | --- | --- |
| `longhorn-fast` | 2 | NVMe/SSD disks tagged `fast` | Coder homes and latency-sensitive development data |
| `longhorn-resilient` | 3 | every disk tagged `storage` | databases and important control-plane application data |
| `longhorn-bulk` | 1 | 7810 HDD tagged `bulk` | large rebuildable caches and build data |
| `longhorn-static` | operator-managed | existing Longhorn volumes | recovery/import only |

All custom Longhorn classes use `Retain`, allow expansion, and reserve space for
Talos and image/container storage. Coder PostgreSQL uses a 10 GiB
`longhorn-resilient` claim. Normal Coder workspaces default to fast storage;
the build template defaults to bulk storage.

Longhorn backs up to `nfs://10.0.0.5:/media/DATA-1/longhorn-backups`:

- Coder database: daily at 03:30, seven retained backups
- Coder workspace volumes: daily at 04:00, three retained backups

Replicas protect against a cluster disk or node failure. Backups protect against
volume loss, but Atlas is still a shared dependency for backup recovery.

### Atlas NFS storage

`nfs-data1` remains the default StorageClass and `nfs-data2` provides secondary
NAS placement. Existing Grafana, Prometheus, Pi-hole, n8n, Portainer, Uptime
Kuma, and Telchar Forge data claims remain on Atlas. If Atlas is unavailable,
those claims and applications are affected; Longhorn-backed Coder data can keep
running locally, but its backup destination is unavailable.

### Container image cache

Spegel `v0.7.4` runs one peer-registry mirror on every node and advertises the
OCI layers retained in that node's Talos containerd content store. Image pulls
try peers before falling back to the upstream registry. This reduces repeated
multi-gigabyte downloads when Coder workspaces move between nodes or GPU
workspaces use the common PyTorch runtime.

Talos is configured through the existing
`/etc/cri/conf.d/20-customization.part` file with
`discard_unpacked_layers = false`. The Spegel chart uses Talos' registry host
directory at `/etc/cri/conf.d/hosts`. `coder-image-cache` keeps the standard
Coder base and universal images referenced on all three nodes;
`coder-gpu-image-cache` keeps the CUDA 12.6 PyTorch image referenced on both GPU
nodes. Mutable `latest` tags bypass the peer cache.

The image cache lives on each node's Talos ephemeral partition. It is not
Longhorn storage, a registry of record, or a backup: a cache miss still needs an
available upstream registry, and cached layers disappear if the node's
ephemeral data is lost.

## GPU compute

Talos on both Precision workers includes the NVIDIA R580 LTS kernel modules and
container toolkit. NVIDIA device plugin `v0.19.3` advertises one GPU from each
node as `nvidia.com/gpu`.

Coder GPU selection is physical and explicit:

- `quadro-m4000` pins the workspace to `precision-5810-01`
- `quadro-p2000` pins the workspace to `precision-7810-01`
- `none` leaves the workspace on normal Kubernetes scheduling

The GPU template uses the PyTorch CUDA 12.6 runtime. CUDA 12.6 retains binary
support for both the Maxwell M4000 and Pascal P2000; a CUDA 13-only image would
drop the M4000.

## Access and service catalog

Most administration services are private tailnet services provisioned by the
Tailscale Kubernetes Operator.

| Service | Tailnet URL | Purpose |
| --- | --- | --- |
| Homepage | `http://olympus-dashboard` | command center and service status |
| Headlamp | `http://olympus-headlamp` | Kubernetes administration |
| NetBox | `http://olympus-netbox` | infrastructure source of truth, IPAM, racks, and cabling |
| Coder | `https://coder.jacob-neel.dev` | public development workspaces; Google SSO |
| Authentik | `https://auth.jacob-neel.dev` | public identity provider and SSO portal |
| Longhorn | `http://olympus-longhorn` | volume and backup administration |
| Grafana | `http://olympus-grafana` | dashboards and GPU visibility |
| Prometheus | `http://olympus-prometheus` | metrics and target health |
| Uptime Kuma | `http://olympus-uptime` | availability monitoring |
| n8n | `http://olympus-n8n` | workflow automation |
| Pi-hole | `http://olympus-pihole` | DNS and ad blocking |
| Portainer | `http://olympus-portainer:9000` | legacy workload operations |

The Tailscale service names also have full `*.taild90e78.ts.net` names. Coder's
canonical access URL is the public HTTPS hostname; its Tailscale LoadBalancer
remains available as a private recovery path.

Coder and Authentik share the remotely managed `olympus-access` Cloudflare
Tunnel. Telchar Dynamics and Telchar Forge use separate tunnels. No inbound
port-forward is required; `cloudflared` establishes outbound connections to
Cloudflare.

### Identity and public access

Authentik runs in namespace `authentik` with PostgreSQL 17.9 on a 10 GiB,
three-replica `longhorn-resilient` volume. Its declarative blueprint creates the
Google source, the Coder and NetBox OpenID Connect providers, and each
application's account policy.
Google sign-in to Coder is restricted to `jacob.neel@gmail.com`; Coder
additionally disables OIDC signups, so an identity cannot create a new Coder
account through the public endpoint. The Google identity links to Authentik's
bootstrap username `akadmin` and to the existing Coder username `jacob-neel`.
Those different usernames refer to the same owner, not duplicate users. The
Coder owner account now uses OIDC; the built-in password form remains globally
enabled during the initial burn-in period.

Cloudflare DNS proxies `auth.jacob-neel.dev` and `coder.jacob-neel.dev` to the
`olympus-access` tunnel. Two `cloudflared` replicas run on separate nodes and
route directly to the cluster services. The Google OAuth client belongs to the
Google Cloud `Homelab` project; its only Authentik callback is
`https://auth.jacob-neel.dev/source/oauth/callback/google/`.

## NetBox infrastructure source of truth

NetBox 4.6.7 runs from the official community Helm chart in namespace
`netbox`. It is private to the tailnet at `http://olympus-netbox`; Authentik
provides the interactive Google sign-in and restricts the application to
`jacob.neel@gmail.com`. A random local administrator is retained only as a
SOPS-encrypted break-glass account.

PostgreSQL 17.9 holds all authoritative inventory on a 10 GiB,
three-replica `longhorn-resilient` volume. Uploaded images use a 5 GiB Longhorn
RWX volume so the web, worker, and housekeeping pods can mount it from different
nodes. The database and media volumes are backed up nightly to Atlas and retain
seven backups. Valkey holds only queues and cache entries and is intentionally
ephemeral.

Operational checks:

```powershell
kubectl -n netbox get pods,pvc,service
kubectl -n netbox get helmrelease netbox
kubectl -n longhorn-system get recurringjob netbox-db-backup netbox-media-backup
```

## Coder development platform

Coder runs in namespace `coder` with a dedicated PostgreSQL 17.9 database on
three-replica Longhorn storage. Kubernetes permissions for workspaces are
confined to that namespace.

Four templates are published from one Terraform source:

| Template | Purpose | Defaults |
| --- | --- | --- |
| `olympus-linux` | everyday Linux development | 4 CPU, 4 GiB RAM, 30 GiB fast disk |
| `olympus-agent` | autonomous coding agents | 6 CPU, 12 GiB RAM, 60 GiB fast disk |
| `olympus-gpu` | PyTorch, CUDA, JupyterLab | 4 CPU, 8 GiB RAM, 80 GiB fast disk, M4000 |
| `olympus-build` | large builds and caches | 8 CPU, 16 GiB RAM, 120 GiB bulk disk, 7810 |

The agent image installs Codex, Claude Code, OpenCode, Reasonix, AgentAPI, and
Node.js 24 into persistent user storage. Editor and agent launchers open in the
selected repository directory.

The `olympus-agent` template also provides an owner-only **Exports** app. Agents
run `olympus-export SOURCE [DOWNLOAD_NAME]` to copy an artifact into the
persistent `/home/coder/exports` directory; the owner can then preview or
download it through Coder in a normal authenticated browser session. The file
service binds only to workspace loopback and is not directly exposed to the
cluster network.

Codex connects to Coder through the authenticated local CLI MCP transport:

```powershell
coder login https://coder.jacob-neel.dev
codex mcp add coder -- C:\Users\Jacob\.local\bin\coder.exe exp mcp server
```

This mode uses the Coder CLI session stored in the operating-system keyring. It
does not require Coder's experimental remote HTTP MCP or OAuth provider flags.

### GitHub integration

The `Olympus Coder Agents` GitHub App provides repository-scoped user tokens.
It has content, workflow, actions, check, status, issue, and pull-request access,
but deliberately does not have repository Administration, Actions-secret, or
webhook permissions. Agents can clone, commit, push, create branches and pull
requests, and operate CI without being able to delete a repository or replace
its core settings.

Workspace creation includes a searchable repository selector. Coder cannot
fetch external data while rendering dynamic parameters, so
[`Publish-CoderTemplates.ps1`](../apps/olympus/coder/template/Publish-CoderTemplates.ps1)
queries the authenticated GitHub CLI at publish time and injects the catalog as
a template variable. Private repository names never enter this public Git
history.

Refresh the catalog after repository access changes:

```powershell
Set-Location D:\repos\homelab\apps\olympus\coder\template
gh auth status
coder login https://coder.jacob-neel.dev
.\Publish-CoderTemplates.ps1
```

## Headlamp administration

Headlamp runs without an implicit cluster-admin token. Create a short-lived
administrator token only when needed:

```powershell
kubectl -n headlamp create token headlamp-admin --duration=24h
```

Paste it into Headlamp and allow it to expire. Helm installation inside
Headlamp is disabled so Flux remains authoritative.

## Talos machine installation guardrails

The Dell Precision firmware can reorder boot devices or fall back between UEFI
and legacy modes after hardware changes or power loss. Keep these rules with any
future node installation:

1. Boot the Talos installer USB in UEFI mode.
2. Inventory every disk by model, serial number, transport, and capacity before
   selecting an install target.
3. Identify the USB explicitly and never use it as the Talos system disk.
4. Confirm the intended internal disk a second time immediately before applying
   a destructive machine configuration. Installing Talos wipes that disk,
   including Windows.
5. After the machine boots Talos from the internal disk, remove the USB and keep
   it reusable for the next node.
6. Set the internal Talos disk as the only normal UEFI boot option. Remove stale
   Windows Boot Manager and legacy boot entries.
7. Verify headless networking after a full shutdown and cold boot before moving
   the machine into the rack.

Do not copy an install-disk path from one Dell to another. Disk enumeration can
change between models, firmware modes, and USB ports.

## Routine operations

### Reconcile and inspect GitOps

```powershell
Set-Location D:\repos\homelab
kubectl kustomize .\infrastructure\olympus
kubectl kustomize .\apps\olympus
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization infrastructure -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
flux get all -A
```

### Cluster health

```powershell
kubectl get nodes -o wide
kubectl top nodes
kubectl get pods -A
kubectl get pvc,pv -A
flux get kustomizations -A
flux get helmreleases -A
```

### Image-cache health

```powershell
kubectl -n spegel get pods -o wide
kubectl -n spegel rollout status daemonset/spegel
kubectl -n spegel get daemonset coder-image-cache coder-gpu-image-cache
```

Spegel exposes Prometheus metrics on port `9090`. Its upstream fallback can hide
a broken peer path, so validate a new installation by pulling the same pinned
image on two different nodes and confirming a mirror success in metrics or the
debug view before relying on cache timings alone.

### Worker maintenance

Before shutting down a Precision worker, stop or move GPU workspaces pinned to
it, then cordon and drain it according to the workload disruption policy. A
single-replica bulk volume on the 7810 cannot run while that node is offline.

Do not casually shut down `optiplex-hermes`: it is the sole control plane and
etcd member. Establish additional control-plane members before treating control
plane maintenance as routine.

### Secret handling

- Create or edit plaintext only in a temporary local file.
- Encrypt with the repository SOPS policy before staging.
- Run `scripts/verify-encrypted-secrets.py` before committing.
- Delete temporary plaintext and copied session tokens after use.
- Never print tokens or secret values into terminal logs or commit history.

## Recovery notes

- Flux can rebuild declarative workloads from this repository.
- SOPS recovery requires both the Git repository and the age private key.
- Coder identity, templates, users, and workspace metadata live in its
  PostgreSQL volume; restore that database before workspace homes when doing a
  full Coder recovery.
- Longhorn backups depend on Atlas `DATA-1`; a NAS failure must be resolved
  before restoring from the backup store.
- NFS application data is not recreated by Flux. Restore it from Atlas backups
  or application-specific exports.
- `Retain` reclaim policies intentionally leave Longhorn volumes behind after a
  PVC is deleted. Confirm ownership before manually removing released volumes.

## Work completed in the 2026 rebuild

1. Installed and boot-verified Talos on the Precision 7810 and 5810 without
   consuming the reusable installer USB.
2. Removed Windows boot paths, standardized UEFI boot, and racked both systems.
3. Added the Precision workers to Olympus and enabled NVIDIA R580 LTS support.
4. Moved the active control-plane role away from the Raspberry Pi fleet to
   `optiplex-hermes`; the Pi systems are currently off.
5. Bootstrapped Flux and migrated infrastructure and application manifests into
   GitOps with SOPS-encrypted secrets.
6. Migrated Homepage, monitoring, Pi-hole, n8n, Portainer, Uptime Kuma, Telchar
   Construct, and Telchar Forge under Flux reconciliation.
7. Deployed Longhorn with NVMe/SSD/HDD tiers and Atlas backup jobs.
8. Rebuilt the Olympus Homepage command center and installed Headlamp.
9. Deployed Coder, its resilient PostgreSQL database, and four development
   templates.
10. Added explicit GPU selection, PyTorch/Jupyter tooling, and autonomous-agent
    launchers.
11. Added a constrained GitHub App, automatic authenticated cloning, and a
    searchable repository selector that avoids leaking private repo names.
12. Deployed Authentik with resilient PostgreSQL storage, Google sign-in, and a
    Coder OIDC application restricted to the owner's Google account.
13. Published Authentik and Coder through the redundant `olympus-access`
    Cloudflare Tunnel and registered the public Coder callback with its GitHub
    App.
14. Converted the existing `jacob-neel` Coder account from password to OIDC and
    verified a fresh Google login returns to the same account and running
    workspace.
15. Added persistent browser-downloadable workspace exports and configured
    Codex to use Coder's local CLI MCP transport.
16. Added a Talos-compatible Spegel peer cache and Coder/PyTorch image
    pre-pullers to avoid repeated large downloads across the compute fleet.

## Known risks and follow-up work

- The cluster has only one control-plane/etcd member.
- Many older applications still depend entirely on the Atlas NFS server.
- Several imported applications still use mutable `latest` image tags and
  should be pinned during normal maintenance.
- Homepage currently has broad read access to cluster objects to populate its
  Kubernetes widgets; its RBAC should be narrowed, especially around Secrets.
- Released Longhorn volumes from disposable Coder smoke tests should be reviewed
  and removed only after confirming they contain no wanted workspace data.
- Coder's password form is intentionally still enabled during OIDC burn-in, but
  the owner account now uses OIDC. Create and test a separate break-glass local
  administrator before disabling the form or relying on it for recovery.
