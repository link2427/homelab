# Atlas Talos migration and recovery record

Atlas was converted from Ubuntu to Talos Linux on August 3, 2026. This record
captures the safety boundary, preserved data, rollback material, and validation
criteria without committing a Talos machine configuration or credentials.

## Immutable disk map

| Purpose | Linux discovery name | Size | Stable identifier | Treatment |
| --- | --- | ---: | --- | --- |
| Talos system SSD | `/dev/sdb` | 500,074,307,584 bytes | `naa.600508b1001ccc3727510b6fbcfa400f` | The only Talos install target |
| DATA-1 | `/dev/sda` | 2 TB | `naa.600508b1001cb89e4d374bdd3944d264` | Preserved, omitted from Talos config, not mounted |
| DATA-2 | `/dev/sdc` | 5.4 TB | `naa.600508b1001c26ef283a748b0dc931a4` | Preserved; never formatted or repartitioned |

DATA-2 partition `/dev/sdc1` retains ext4 UUID
`dc8063bd-b33c-409a-83ea-7d98fb74ad8b`. Talos mounts it at
`/var/mnt/data-2`. Device names are diagnostic only; configuration must use the
stable SSD WWID and DATA-2 filesystem UUID.

## Migration outcome

- Talos `v1.12.6` boots from the 500 GB SSD and survives a cold reboot.
- Kubernetes node `atlas` is a worker at `10.0.0.5` with 72 logical CPUs and
  approximately 64 GiB RAM.
- Longhorn uses only `/var/lib/longhorn` on the SSD, with 150 GiB reserved.
- DATA-1 is not mounted, scheduled, formatted, or used by Longhorn.
- Samba exports DATA-2 at `\\10.0.0.5\DATA-2` with authenticated read/write
  access.
- Plex metadata is on replicated Longhorn storage. Media is mounted read-only
  from `/var/mnt/data-2/Plex Media`.
- Plex retained machine identifier
  `8d12412f4798ffc375c821bd549bf795a56cf331` and version
  `1.42.2.10156-f737b826c`.
- Plex sees Tesla P40 UUID `GPU-263abd8a-ce4b-a904-435b-ba79c2a3186a`, 24 GiB,
  through the Talos NVIDIA runtime.
- Forge PostgreSQL and the other migrated application volumes are healthy with
  three Longhorn replicas. Forge PostgreSQL's Atlas replica completed its final
  rebuild after the image-cache pulls finished.
- Bulk DATA-2 media was deliberately not copied to Longhorn or R2.

The temporary Talos ISO server is scaled to zero and its NodePort has been
removed. Its deployment and 2 GiB Longhorn recovery volume remain available,
along with the local migration artifacts, so virtual-media recovery can be
re-enabled deliberately without leaving an installer exposed.

## Rollback material

Encrypted rollback archives are retained under `I:\atlas-migration` and also
on DATA-2 under `atlas-migration`:

| Archive | SHA-256 |
| --- | --- |
| `atlas-retirement-2026-08-02.tar.gz.age` | `5a7b803288c10815e5369cde8f7ea46d52c24b1cdd0469cfd5ef7f0fdd885419` |
| `atlas-plex-metadata-2026-08-02.tar.gz.age` | `9fba0137d179d4a7810ee01920685539b4b25ab8b7bbdc0de08a3468208c6ff4` |

The retirement archive contains selected Ubuntu host configuration and
application state; the Plex archive contains the pre-conversion Plex metadata.
Hermes was intentionally excluded. Keep these archives until a later, explicit
retention decision. Do not commit their encryption identity or decrypted
contents.

## Final backup and health gate

The final application backup run completed on August 3, 2026. The following
Longhorn backups report `Completed`, 100% progress, and Cloudflare R2 URLs:

| Application data | Backup |
| --- | --- |
| Grafana | `backup-2adccc16f29e4490` |
| Plex metadata | `backup-40b19bdecd614e90` |
| Forge PostgreSQL | `backup-2a5ab8b1f8cf4356` |
| Forge NATS | `backup-4860da24d61043ee` |
| Uptime Kuma | `backup-c8eb4f1ccbc8486a` |
| Portainer | `backup-35b8f64e35ac4835` |
| n8n | `backup-bb5cb7216c734c22` |
| Prometheus | `backup-9e0871773e474cd0` |
| Forge Redis | `backup-4282dbb56a2f4593` |
| NetBox PostgreSQL | `backup-dbd926fa3c214e77` |

The R2 backup target was available and synced after this run. A disposable
backup/restore checksum gate also passed before the migration. These backups
contain application volumes only; the bulk DATA-2 library remains excluded.

The final Talos cluster health gate passed for the control plane and all three
workers: etcd membership, apid, diagnostics, boot sequence, kubelet, Kubernetes
node readiness, control-plane static pods, kube-proxy, CoreDNS, and scheduling
all reported healthy. All Flux Kustomizations and Helm releases reconciled to
the latest `main` revision, all image-cache DaemonSets reached their desired
count, and all attached Longhorn volumes reported healthy.

## Operational validation

```powershell
kubectl get node atlas -o wide
kubectl -n plex rollout status deployment/plex
kubectl -n nas rollout status deployment/samba
kubectl -n longhorn-system get node.longhorn.io atlas
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get backuptarget.longhorn.io default
```

For Talos inspection, override the stale default endpoint and name Atlas
explicitly:

```powershell
talosctl --talosconfig <talosconfig> --endpoints 10.0.0.5 --nodes 10.0.0.5 get disks
talosctl --talosconfig <talosconfig> --endpoints 10.0.0.5 --nodes 10.0.0.5 get machinestatus
```

Before any future reinstall, confirm the three stable identifiers above from
the live disk inventory. Stop if any identifier or capacity differs.
