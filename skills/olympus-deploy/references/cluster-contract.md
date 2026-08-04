# Olympus cluster contract

This is public-safe operational context. It intentionally contains no tokens,
private keys, kubeconfigs, Talos secrets, decrypted Kubernetes Secrets, or
provider credentials.

## Source of truth

- Repository: `https://github.com/link2427/homelab`
- Flux watches branch `main` and path `clusters/olympus`.
- Reconciliation order is `flux-system` → `infrastructure` → `apps`.
- Application resources live under `apps/olympus/<app>`.
- Cluster-wide controllers and shared facilities live under
  `infrastructure/olympus/<component>`.
- Direct changes to Flux-owned resources will be reconciled back to Git.

Always inspect the current repository before relying on this summary.

## Platform

- Talos Linux on x86-64 nodes; do not use node SSH or host package managers.
- Kubernetes with Flux, Kustomize, and SOPS age decryption.
- Flannel CNI without a NetworkPolicy enforcement engine.
- Longhorn for distributed application storage and Cloudflare R2 backups.
- Spegel for peer-to-peer container image caching.
- Tailscale operator for private application access.
- Cloudflare Tunnel and Authentik for explicitly approved public applications.
- NVIDIA device plugin with the `nvidia` RuntimeClass.
- Headlamp for human cluster administration.
- Coder for development workspaces; it does not own normal application
  deployments.

## Storage classes

| StorageClass | Replicas | Intended use |
| --- | ---: | --- |
| `longhorn-fast` | 2 | Normal SSD-backed application state and development data |
| `longhorn-resilient` | 3 | Databases and important, difficult-to-rebuild state |
| `longhorn-bulk` | 1 | Large rebuildable caches/build data on bulk storage |

All three Longhorn classes expand volumes and use `Retain`. Capacity and replica
placement still need live verification before creating large claims.

The legacy `nfs-data1` and `nfs-data2` StorageClasses remain for rollback. Their
dynamic provisioners are scaled to zero; do not use them for new claims. Existing
static NAS volumes are application-specific and require explicit approval.

For normal durable application PVCs, use:

```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    recurring-job.longhorn.io/source: enabled
    recurring-job.longhorn.io/olympus-app-backup: enabled
```

The `olympus-app-backup` recurring job currently creates daily R2 backups and
retains seven. Confirm the job and backup target are healthy rather than merely
assuming the labels guarantee a successful backup.

## GPU inventory

| Node selector value | GPU | VRAM | Notes |
| --- | --- | ---: | --- |
| `precision-5810-01` | Quadro M4000 | 8 GiB | General small GPU workloads |
| `precision-7810-01` | Quadro P2000 | 5 GiB | Normally assigned to Plex transcoding |
| `atlas` | Tesla P40 | 24 GiB | Primary larger compute accelerator |

GPU scheduling requires all of:

```yaml
runtimeClassName: nvidia
nodeSelector:
  kubernetes.io/hostname: atlas
containers:
  - resources:
      limits:
        nvidia.com/gpu: "1"
```

Select the exact node; do not request an anonymous GPU because the cards have
different capabilities and existing assignments. Check current allocation
before deployment.

## Access classes

1. `ClusterIP`: internal service-to-service access; safest default.
2. Tailscale `LoadBalancer`: private human or machine access through the
   tailnet.
3. Cloudflare Tunnel: public Internet path, normally paired with Authentik when
   the application supports the flow. Requires explicit domain and exposure
   approval.

Do not assume an application is safe for the Internet because it has its own
login page. Do not create a public route with a default password or unfinished
bootstrap account.

## Known architectural constraint

Kubernetes `NetworkPolicy` objects may document intended connectivity, but
plain Flannel does not enforce them here. A pod can potentially reach sensitive
cluster-internal services even when it has no Kubernetes RBAC. Do not place an
untrusted autonomous workload in a normal pod and call it isolated solely
because a NetworkPolicy exists.
