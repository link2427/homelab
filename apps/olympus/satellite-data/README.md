# SatelliteDataApi on Olympus

The release is built from `link2427/SatelliteDataApi` commit
`b0f099529469f38da5b545d143a669c2c59fb48b` on `codex/cluster-migration`.
The build workflow lives on `codex/olympus-deployment`; its checkout is pinned to
that exact application revision. No legacy continuous .NET worker is deployed.

## Environments and ownership

| Setting | Development | Production |
| --- | --- | --- |
| Namespace / Flux Kustomization | satellite-data-dev | satellite-data-prod |
| Writable root | /data/dev | /data/prod |
| PVC | satellite-data, 2Gi longhorn-fast | satellite-data, 5Gi longhorn-resilient |
| S3 bucket | cosmotrak-data-dev | cosmotrak-data |
| IAM user | olympus-satellite-dev | olympus-satellite-prod |
| Routine schedule | suspended | enabled, minutes 7/22/37/52 UTC |

Both S3 targets are in `us-east-1`. **Released clients require production keys
`Satellite_Database/satellite-database-YYYY-MM-DD.db`. Keep that contract.**
The new dev bucket blocks all public access, uses AES256 encryption, and has
versioning enabled. Each identity can list its prefix and get/put its objects;
each explicitly denies access to the other environment. Production bucket
policy, encryption and existing client download permissions are preserved.
Runtime and registry credentials are SOPS encrypted. The dedicated GHCR
read:packages token expires September 5, 2027; rotate it before then.

Independent Flux Kustomizations avoid coupling releases to unrelated aggregate
`apps` health failures. Do not also add these directories to the aggregate apps
kustomization. Durable PVCs have Retain policy, disabled Flux pruning, and the
daily `olympus-app-backup` R2 backup label (seven retained backups).

## Single publisher and scheduling

There is one CronJob per environment: every 15 minutes UTC, Forbid concurrency,
no job retries, 6000-second deadline, and the publisher's volume-wide POSIX lock.
The persisted `next_attempt` gates daily ingestion. An early check makes no
upstream requests and is not proof of successful publication.
Production checks at minutes 7/22/37/52. This retains the recovered Mac deadline
without firing just before its satellite refresh becomes 24 hours old: the
first due ingestion check is September 7 at 04:22 UTC. Future successful full
runs schedule themselves 24 hours after completion.

September 6 cutover evidence: dev published at 06:07:29 UTC and production
published at 06:10:21 UTC. The independent anonymous production download returned
200 and 20,443,136 bytes, SHA-256
`d30a6d942e00edad7ddc50b40d34aaafcf7f7fe1ba491f8c6e316a097a95b721`.
The validated catalog has 14,631 satellites refreshed at 04:15:55 UTC and a
median TLE epoch of September 5 at 15:06:35 UTC. Dev anonymous downloads return
403. CI run `34015125354` passed 28 .NET tests, 27 Python tests, both preflights,
the container build, and restricted runtime checks.

Dev stays suspended. Use a copied candidate and `--reuse-snapshot` for routine
validation or a deliberate dev upload. Never put production credentials or the
production PVC into dev. Flannel does not enforce NetworkPolicy here; namespace
separation is not a claim of network isolation.

The status Deployment has one replica and Recreate updates. It mounts the PVC
read-only and has no S3 credential or Kubernetes service-account token. Publisher
Jobs require affinity to that status pod's node so they share the RWO volume
without changing SQLite storage guarantees. This means jobs wait if the status
pod cannot be scheduled; monitoring must alert on missed checks.

## Status endpoints

All responses have `Cache-Control: no-store`.

| Path | Meaning |
| --- | --- |
| /health/live | HTTP process liveness and readiness |
| /status | Sanitized publisher summary, available even when data is unhealthy |
| /health/data | 200 for healthy verified data; 503 for failure or stale/missing evidence |

Cluster URLs are `http://satellite-data-status.satellite-data-ENV.svc.cluster.local`.
Production also has private Tailscale hostname `olympus-satellite-data`.
Dev is ClusterIP only. No public DNS or Cloudflare route is created.
Use `/health/live` for pod probes. Never restart ingestion in response to
`/health/data`; an upstream outage or stale database requires investigation.
Future monitoring should run outside Olympus, alert only on failure/recovery
transitions, and independently download the actual S3 object. A future website
route can proxy the sanitized production summary on the same origin.

## Cutover and rollback

1. Build/test the image, pin its digest, deploy both CronJobs suspended and
   production `allow_production_publish=false`.
2. Seed separate PVCs. Validate dev offline, then publish/download in the dev
   bucket and verify checksum, table counts, TLE checksums and freshness.
3. Verify old publishers stopped. The user shut the Mac down manually and
   waived transfer of its local files. EC2 instance `i-074513254839e9c76` was
   independently observed stopped. The EC2 GitHub deploy workflow is disabled.
4. The S3 September 6 snapshot and its matching publication log recover all
   published database rows plus `next_attempt=2026-09-07T04:14:47.412492+00:00`.
   The Mac working database, unpublished changes and full provider caches were
   not transferred. One targeted CelesTrak request recovered authentic source
   evidence for NORAD 41929's future epoch; no full ingestion was repeated.
   Preserve the recovered deadline, retain the original S3 snapshot/checksum,
   and conservatively retain that deadline as the CelesTrak cooldown as well.
5. Opt production into publishing, run one controlled `--reuse-snapshot
   --publish` job, verify a new S3 LastModified and matching SHA-256 after an
   independent application-compatible download, then unsuspend only production.
   Reusing a still-fresh snapshot creates a new verified publication; it does
   not claim a new upstream ingestion. The next due job performs ingestion.
6. Take and verify initial Longhorn R2 backups. Retain source recovery data.

For rollback, first set production `suspend: true` in Git and reconcile. Suspend
does not stop an active Job: await its termination or explicitly stop that exact
job before starting any alternate publisher. Restore a verified backup into a
new PVC if needed. Do not enable the Mac or EC2 while a cluster writer exists.
The old Mac installation and historical S3 objects remain recovery copies.

## R2 dual publication next

Keep S3 enabled permanently as the compatibility mirror for released clients.
Build one validated SQLite candidate with a SHA-256 content identity. Record
independent S3 and R2 put/download verification evidence and retry deadlines;
retry a failed destination without another ingestion or falsely marking both
deliveries successful. Use conditional writes and a single publisher lock.

Create a separate R2 bucket and credentials per environment. Test both success
and partial-failure cases in dev: R2 failure must not disable S3 delivery, S3
failure must remain unhealthy for compatibility, and download checksum mismatch
must prevent a success marker. Keep immutable dated objects on both targets.

After dual delivery is proven, publish an atomic manifest through
`data.cosmotrak.com` with schema version, generated time, object URL, size and
SHA-256. New apps can consume that stable endpoint; old apps continue to use S3.
Authorize the public hostname separately and use a production custom domain,
not the R2 development URL. No R2 data destination or client switch is enabled
by this deployment. Longhorn's R2 backups are a separate recovery mechanism.

References: [migration guide](https://github.com/link2427/SatelliteDataApi/blob/b0f099529469f38da5b545d143a669c2c59fb48b/docs/cluster-migration.md),
[CelesTrak GP queries](https://celestrak.org/NORAD/documentation/gp-data-formats.php),
[R2 public buckets and custom domains](https://developers.cloudflare.com/r2/buckets/public-buckets/).
