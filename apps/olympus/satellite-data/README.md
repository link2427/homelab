# SatelliteDataApi on Olympus

Current deployment: [September 12 qualified UTC export and dual-delivery release](release/2026-09-12.md).
Both environments run `218cfc8`. Production publishes one compatible snapshot to
S3 and private R2 with independent receipts; modern clients discover it through
`https://data.cosmotrak.com/v1/manifest.json`. Shipped clients retain the dated S3
path. Development remains private and unscheduled. The sections below retain
the original cutover and September 11 recovery history.

Production builds from `SatelliteDataApi/main`; development builds from `dev`.
Both use the September 11 recovery changes described in the
[publisher recovery runbook](https://github.com/link2427/SatelliteDataApi/blob/main/docs/publisher-recovery.md).
Production preserves its released SQLite format and S3 delivery path. Development
retains private R2 and Horizons v2; its routine CronJob remains suspended and
CelesTrak network access defaults to disabled. See the [development runbook](dev/README.md).
The EC2 workflow stays disabled and no legacy continuous worker is deployed.

## Recovery and monitoring

The September 10 failure was a 20-second CelesTrak response timeout. The outer
publisher incorrectly deferred retry for a full day even though the provider
cooldown was two hours. Timeout is now 60 seconds with a 10-second connect limit.
Transient failures persist a two-hour minimum wait plus jitter, with exponential
backoff capped at 12 hours; longer Retry-After values win. There are no immediate
HTTP or Kubernetes retries. Partial responses stay cached, permanent errors hold
all automatic requests for review, and storage retries reuse a validated candidate.

The reviewed legacy attempt was September 10 at 05:07:01.225776 UTC. A one-time
GitOps Job backed up status and all 40 provider state/cache files to
`/data/prod/backups/before-recovery-20260911T030343Z`, then set eligibility to
September 11 at 04:36:38 UTC. It made zero upstream requests, preserved cache
hashes and publication timestamps, and was retired after verification. The floor
includes the single 02:31:38 diagnostic request. Do not run that review again.

Prometheus scrapes `/metrics` every 30 seconds and has alerts for a failed update,
operator hold, missing status, heartbeat over 45 minutes, retry over 30 minutes
late, and catalog age over 30/36 hours. A healthy CronJob exit alone is insufficient.
The public [status page](https://cosmotrak.com/status) explains failures and retry
eligibility; its Refresh button never starts ingestion.

`scripts/check-satellite-data.py` runs outside Olympus. It checks the public API,
validates the allowlisted public object identity, HEADs the existing S3 download,
and verifies its full SHA-256 once per new hash or day. It never contacts CelesTrak.
The Codex heartbeat runs every 15 minutes and emails the owner's connected Gmail
account on failure/recovery changes only. It acknowledges an event only after
successful delivery, so a send failure is retried. Its local state is
`.ai-context/satellite-email-monitor.json`. The workstation and Codex must be
available for that external email monitor; cluster alert rules remain active
independently. No email credentials are stored in Git.

Source branches are `main` and `dev`; use one short-lived branch per actual PR,
delete it after merge, and prune stale remote references. Auto-delete after merge
is enabled. Old branches were archived in verified local Git bundles before removal.

## Environments and ownership

| Setting | Development | Production |
| --- | --- | --- |
| Namespace / Flux Kustomization | satellite-data-dev | satellite-data-prod |
| Writable root | /data/dev | /data/prod |
| PVC | satellite-data, 2Gi longhorn-fast | satellite-data, 5Gi longhorn-resilient |
| Delivery bucket | private R2 cosmotrak-data-dev | AWS S3 cosmotrak-data |
| Publishing identity | bucket-scoped R2 token | olympus-satellite-prod |
| Routine schedule | suspended | enabled, minutes 7/22/37/52 UTC |

Production and the retained rollback-only dev S3 bucket are in `us-east-1`.
**Released clients require production keys
`Satellite_Database/satellite-database-YYYY-MM-DD.db`. Keep that contract.**
The dev R2 bucket has no public domain and uses a dedicated bucket-scoped token.
The original dev S3 data and encrypted credentials remain available for rollback.
Production bucket policy, encryption and client download permissions are preserved.
Runtime and registry credentials are SOPS encrypted. The dedicated GHCR
read:packages token expires September 5, 2027; rotate it before then.

Independent Flux Kustomizations avoid coupling releases to unrelated aggregate
`apps` health failures. Do not also add these directories to the aggregate apps
kustomization. Durable PVCs have Retain policy, disabled Flux pruning, and the
daily `olympus-app-backup` R2 backup label (seven retained backups).

## Single publisher and scheduling

There is one CronJob per environment: every 15 minutes UTC, Forbid concurrency,
no job retries, 6000-second deadline, and the publisher's volume-wide POSIX lock.
The persisted `next_attempt` and recovery deadline gate ingestion. An early check makes no
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
The full private hostname is `olympus-satellite-data.taild90e78.ts.net`
(`100.81.168.98`). No NodePort is allocated. Liveness, summary and data health
were verified through the internal Services and the Tailscale route. Runtime
acceptance also tested fresh, stale, failed, missing and malformed status:
data health returns 503 for bad data while liveness and summary remain 200.
Use `/health/live` for pod probes. Never restart ingestion in response to
`/health/data`; an upstream outage or stale database requires investigation.
Monitoring runs outside Olympus as described above; the website proxies a
sanitized production summary. Private exception text, paths and credentials are
excluded from the public contract.

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

Both initial backups, `satellite-dev-initial-20260906` and
`satellite-prod-initial-20260906`, reached Completed / 100% in the existing
`olympus-longhorn-backups` R2 target. Dev has two healthy Longhorn replicas;
production has three. Restore drills were not performed during this cutover.

Provisioning the private status route exposed a pre-existing Tailscale operator
crash loop: version 1.102.3 expected the absent PeerRelay CRD. GitOps now includes
that version's upstream CRD and matching resource permissions, and pins the
operator to its already-running digest. The operator and new status proxy are
healthy. Other offline-node proxy recovery is outside this migration.

## Future production R2 dual publication

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
for production by this deployment. Development uses only its private R2 destination.
Longhorn's R2 backups are a separate recovery mechanism.

References: [migration guide](https://github.com/link2427/SatelliteDataApi/blob/b0f099529469f38da5b545d143a669c2c59fb48b/docs/cluster-migration.md),
[CelesTrak GP queries](https://celestrak.org/NORAD/documentation/gp-data-formats.php),
[R2 public buckets and custom domains](https://developers.cloudflare.com/r2/buckets/public-buckets/).
