# SatelliteDataApi development on private R2

Development uses the existing `satellite-data-dev` namespace, independent Flux
Kustomization, and `satellite-data` PVC. Routine ingestion remains suspended.
Production's image, database/PVC, credentials and AWS S3 delivery are unchanged.

## Verified release, September 10, 2026

- Backend `dev`: `6ad1ddc21f7a5075067c1e9f739c0cb432589ee8`.
- Image: `ghcr.io/link2427/satellite-data-api@sha256:fa1d7dea2f700ad77768ab2399b86055f703a2518d44c44cb1c1451a9d9dcb3e`.
- [Linux CI run 34441178326](https://github.com/link2427/SatelliteDataApi/actions/runs/34441178326): 37 .NET tests, 34 Python tests, 21 Horizons contract checks / 178 frozen vectors, configuration preflights and restricted container checks passed.
- Fixtures match Cosmotrak `1.6` commit `ccc832b99ae9b9ff16cc29024be5feb31828a021`, including its committed `Validation/fixtures` manifest.
- R2 bucket: `cosmotrak-data-dev`, private; `r2.dev` disabled and no custom domains.
- Secret: `satellite-data-r2`, bucket-scoped object read/write credentials encrypted in `r2.secret.yaml` through existing SOPS rules. Access to other buckets was denied. The status pod has no storage credentials.

The controlled GitOps job `satellite-dev-r2-retry-20260910` freshly regenerated
Horizons and published at `2026-09-10T05:37:12Z`. It was removed from the declared
resources after verification so reconciliation cannot recreate it. The one-time
migration/catalog import job and script remain available in Git history, not as
scheduled workloads. Do not repeat the completed storage migration or import.

Independent R2 download:

```text
Satellite_Database/satellite-database-2026-09-10.db
20,443,136 bytes
SHA-256 82ef2a5a650560191bcbb5e67433c6203aacc79f6a7e651c07577287a49d5390
```

SQLite integrity and foreign keys passed. All retained vector targets now use
`ICRF/J2000 equatorial; UTC; v2`, with no legacy `CalendarDateTdb` values. Body
and spacecraft coverage begins September 7 and normally ends October 25; MRO
has 81 freshly generated samples through September 27, reflecting JPL's shorter
available prediction window. Orbit paths retain their longer per-body windows.
All 11 bodies, 10 orbit targets and 15 retained spacecraft were preserved.

The first refresh failed safely on an explicit MRO upper boundary labeled `UT`.
All five Horizons tables exactly matched the pre-upgrade backup after rollback;
no database was published. The corrected release supports both `UT` and `TDB`
boundary errors, retries once using the preceding UTC calendar day, and retains
the strict frame/time contract. Only the subsequent successful refresh counts
as regenerated data.

All 8,001 launches and their exact row content are preserved, as are agencies,
launcher configurations, news/media/facts, and all pagination states. The launch
cursor remains `limit=100&offset=5300&ordering=-net`. The two CelesTrak cache/
cooldown files and the original `last_attempt` / `next_attempt` are unchanged.
No Launch Library historical import or other feed ingestion was started.

During the existing shared CelesTrak cooldown, only `Satellites` and `LastUpdates`
were copied from the checksum-verified September 9 production S3 export. This
reused 14,622 satellite records with their authentic refresh timestamp
`2026-09-09T04:53:29Z`; it did not claim a new satellite ingestion. Source SHA-256:
`0e9325b2c87ac5598b3562aeff1fba954e1ea3aca5b20d0c1d163e54ae89f31d`.
Its existing 26-hour publication freshness gate passed during this run and is
not bypassed on subsequent runs. Dev health will become stale without another
deliberately authorized refresh because routine ingestion is suspended.

At verification, `/health/live`, `/status` and `/health/data` returned 200 with
`Cache-Control: no-store`. R2 anonymous S3 API access was rejected for missing
Authorization; the public managed domain remains disabled. Live conditional
write checks rejected duplicate creation and stale ETags with 412, accepted the
correct ETag, and verified the downloaded checksum. Temporary probes were removed.

## Controlled operations

Use the current backend [R2 runbook](https://github.com/link2427/SatelliteDataApi/blob/dev/docs/r2-development.md).
Build the actual `dev` commit with Linux CI and pin its digest only in this
directory's status Deployment and suspended CronJob. Wait for the status pod to
be ready before adding a uniquely named one-off Job through this Kustomization.
Copy the CronJob's security context, RWO affinity, mounts, deadline and zero job
retries. Confirm no other dev publisher is active.

For an intentional Horizons refresh, use the existing working database:

```sh
python3 /app/scripts/local_publisher.py /config/publisher.json --refresh-horizons
python3 /app/scripts/local_publisher.py /config/publisher.json --reuse-snapshot --publish
```

Run the commands sequentially with failure propagation. Regeneration and verified
delivery are separate outcomes. An expired satellite freshness gate must be
resolved with an authentic, deliberately controlled update after cooldown;
never reset timestamps, cursors or caches. A failed upload can be retried with
only `--reuse-snapshot --publish`, subject to the unchanged validation gates.
Archive logs, independently download/check the object, verify data health, then
remove the completed Job from declared GitOps resources. Keep `suspend: true`.

## Recovery retained

- Existing AWS dev bucket `cosmotrak-data-dev` and its September 6 database/log objects remain unchanged. The separate `satellite-data-s3` encrypted secret and `s3-rollback.json` are retained; current publishing mounts only the R2 credentials.
- Pre-migration backup on the original PVC: `/data/dev/backups/before-r2-20260910T052358652543Z`, eight files with a verified SHA-256 manifest. SQLite backups include working, candidate, baseline and bootstrap data alongside state/status/target metadata.
- Independent off-PVC archive: `dev-before-r2-20260910.tar`, 81,827,840 bytes, SHA-256 `086fcdc3a42312f2ceab0dc75c933e26d64df078fb9d5e6bdb5174b4af9c810a` in the private coordination workspace's `satellite-dev-evidence` directory.
- Longhorn backup `backup-f7a6ffc40f6840c5` completed September 10 at 02:27 UTC. The original dev volume `pvc-b9cbfd73-aa8e-4ff8-8bbc-2203e00f1a86` retains two healthy replicas.

For rollback, keep dev suspended and confirm its writer has stopped. Preserve a
fresh copy of current dev data first. Restore the verified pre-migration dev
databases, status, state and target marker together while idle; select the old
S3 config/mount and previous image through dev-only GitOps. Changing only the
bucket or image is insufficient because the target guard intentionally rejects
mixed state. Keep the existing PVC and all recovery copies. Do not touch the
production namespace or resume legacy external publishers.

Production remains on image digest
`sha256:f2748e998997c430e529311af2c0a78bd0979fc40a881b01c7e4c909cd3f2512`,
its existing PVC and credentials, and
`cosmotrak-data / Satellite_Database/satellite-database-YYYY-MM-DD.db`.
Production S3 objects and compatibility delivery were not changed.
