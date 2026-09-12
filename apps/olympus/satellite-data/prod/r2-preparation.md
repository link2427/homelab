# Production R2 release preparation — September 12, 2026

This is preparation for the Cosmotrak iPhone 1.6 / Mac 1.0 release. No new
backend candidate or public delivery route is deployed by these files.
Production continues to use its existing image, PVC, AWS credentials and
`cosmotrak-data/Satellite_Database/satellite-database-YYYY-MM-DD.db` delivery.

## Private storage ready

- R2 bucket `cosmotrak-data-prod`, default jurisdiction, ENAM, Standard, created September 12 at 22:09:58 UTC.
- Managed `r2.dev` access is disabled; no custom domains are attached.
- Dedicated account token `Olympus SatelliteDataApi production`: object read/write/list only for this bucket. Dev and Longhorn backup bucket access were independently denied with 403.
- `r2.secret.yaml` contains the SOPS-encrypted `satellite-data-r2` Secret for namespace `satellite-data-prod`, key `credentials.json`, using the existing publisher credential JSON fields. Encryption round-trip and real scoped access passed.
- The Secret is deliberately **absent from kustomization.yaml and all pod mounts** until the validated candidate's configuration is ready. Existing S3 and registry Secrets remain unchanged.

## Proposed delivery contract, awaiting release freeze

`data.cosmotrak.com` was verified unused in DNS and Worker custom domains. It
matches the hostname already proposed by the existing SatelliteDataApi runbook.
No DNS, tunnel route, Worker route, preview URL or public bucket access was created.

| Public path | Private R2 key | Cache-Control |
| --- | --- | --- |
| `/v1/manifest.json` | `v1/manifest.json` | `no-cache,max-age=0,must-revalidate` |
| `/v1/databases/<sha256>.db` | `v1/databases/<sha256>.db` | `public,max-age=31536000,immutable` |

Allow only unauthenticated HTTPS GET/HEAD for those exact paths; the database
name must be a canonical 64-character lowercase SHA-256. Never expose arbitrary
keys, listings, state, logs or write methods. Native downloads must work without
cookies, browser challenges, signed expiring URLs or app-embedded credentials.

The coordinator's proposed manifest format is `cosmotrak-database-manifest-v1`,
with `backend_commit`, `environment` and `database` fields: `url`, `sha256`,
`size_bytes`, `generated_at_utc`, `schema_version: 1`, `coordinate_version: 2`,
`reference_frame: "ICRF/J2000 equatorial; UTC; v2"`, `time_scale: "UTC"`,
`position_unit: "km"`, and `velocity_unit: "km/s"`. Freeze this contract with
the release coordinator before enabling routing or publishing the manifest.

A small Worker with a private R2 binding can stream these allowlisted objects
without adding a storage credential to the existing status pod. Retain its
source/configuration and version evidence in Git. Preparation must explicitly
disable `workers_dev` and `preview_urls` and omit routes/custom domains.
See [R2 Worker bindings](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/),
[workers.dev configuration](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/),
and [preview controls](https://developers.cloudflare.com/workers/versions-and-deployments/preview-urls/).

## Data and compatibility gates

Both existing environments were snapshotted through SQLite backup under a shared
publisher lock at September 12 22:09:24 UTC. Status, caches, logs and table hashes
were retained; no upstream requests or state changes were performed. Both PVCs
and September 12 Longhorn backups were healthy/Completed 100%.

The verified September 12 production S3 database is 20,443,136 bytes, SHA-256
`62f0b7136b539080f3d8c4b2372aef2653d71bae86e76f5b61815e582481150c`.
It has 14,618 satellites, 8,001 launches, and legacy `ICRF/J2000` vector metadata
with non-null TDB calendar fields. Its launch cursor is now
`limit=100&ordering=-net`, updated September 12 04:53:48 UTC. Do not overwrite it
with dev's older offset-5300 cursor.

Production MRO still contains June 6–July 24 samples generated June 9. The other
14 retained spacecraft have September 9–October 27 coverage generated September
12. Dev's separately regenerated UTC/equatorial MRO covers September 7–27, and
the other 14 spacecraft cover September 7–October 25. Do not relabel the old
production vectors as corrected data. Freeze all 15 existing spacecraft, 11
bodies and 10 orbit targets before the candidate's genuine capture; replay must
reject any required failed target and run without network access.

The Mac release coordinator owns the single genuine JPL capture. Do not run a
concurrent Horizons refresh from Olympus. Current production CelesTrak response
caches and provenance are in the private release handoff; do not repeat downloads
or change timestamps/cooldowns to satisfy validation. Current next production
ingestion deadline is September 13 04:55:01 UTC, subject to subsequent live state.

Before promotion, execute the shipped-reader gate against the corrected export.
Whether S3 can deliver the same corrected bytes or needs a separate compatible
export remains a release gate. Keep dated S3 delivery fresh, preserve independent
destination status/conditional-write evidence and retry deadlines, and never
rerun ingestion for a storage-only retry.

No application or notification source was changed in this preparation. Snapshot
bundles and temporary access links are kept only in the private coordination
workspace; they contain no storage credentials and are not public Git artifacts.
