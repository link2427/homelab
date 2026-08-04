# Plex storage and backup boundary

Plex reads its media from the static `plex-media-data2` NFS volume backed by
Atlas DATA-2. This volume is outside Longhorn and must never be copied into a
Longhorn PVC or an external backup target.

The `plex-config` Longhorn claim stores only Plex application configuration and
metadata. It intentionally has no Longhorn recurring-backup labels. Neither the
config claim nor any media-automation/download claim may opt into the
Cloudflare R2 backup jobs.

All Plex-related storage carries the `olympus.dev/backup-policy: never-r2`
annotation as a visible audit marker. This annotation documents the policy;
the enforced behavior comes from keeping every
`recurring-job.longhorn.io/*-backup` label off these claims.
