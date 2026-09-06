# Personal website on Olympus

Public URL: https://jacob-neel.com. Cloudflare zone
`fe30bfa48a36527b0ac45dfe3dc6e2cf`; shared tunnel `olympus-access`
`3fb7dbb0-08b5-4003-895c-1c2c0ea858ca`. Apex and www route to
`http://personal-website.personal-website.svc.cluster.local:80`. The app
redirects www to apex; Cloudflare upgrades HTTP to HTTPS.

Independent Flux Kustomization `personal-website` owns this directory. Do not
also add it to aggregate apps. Private source and image:
`link2427/Personal-Website`, `ghcr.io/link2427/personal-website`.
Main CI builds, smoke-tests pages and package tools, publishes the image and
updates this immutable image pin through a dedicated write deploy key.

The restricted web pod runs as UID1000 without an API token, with a read-only
root and bounded temporary storage for npm/pip archives. Python/pip support the
existing package-download tools. CF-Connecting-IP supplies visitor IPs through
Cloudflare Tunnel. Health probes bypass analytics; readiness checks PostgreSQL.

## Database and recovery

The user chose a fresh cluster database because Railway was already refusing
connections. No Railway data was imported, erased or modified. `init.sql`
initializes the six existing Drizzle tables only on an empty volume. Future
schema changes need reviewed migrations and backups. The web database role has
no superuser or role-creation privilege. Existing admin password/salt remain.

PostgreSQL 17.9 uses a retained 4Gi `longhorn-resilient` PVC requesting three
replicas. At migration, only Atlas had logical scheduling capacity. Existing
Longhorn policy permits starting degraded with one replica. Do not claim three
healthy copies until live status confirms them. Do not raise global storage
overprovisioning or delete unrelated volumes to conceal this limitation.
`olympus-app-backup` backs up daily at 02:00 UTC to R2 and retains seven copies.
Verify an initial backup at cutover. The PVC is excluded from Flux pruning.

Revert image pins through Git. Database recovery needs a PostgreSQL dump or
Longhorn backup restore; reverting Git does not reverse data changes. EC2's
application remains available for rollback, but still points at failed Railway;
restoring service through it requires a deliberate database connection change.

## Credentials and dependencies

Runtime, PostgreSQL and registry credentials are SOPS encrypted. The registry
token has read:packages only and expires September 5, 2027; renew before expiry.
The source Actions secret `HOMELAB_DEPLOY_KEY` holds its dedicated homelab write
deploy key 162426151. CI has no cluster or runtime database credentials.

Ollama, legacy hardware metrics and Raspberry Pi live ADS-B were already offline
before migration. The separate ADS-B deployment workflow still uses EC2 as a
staging hop; review that and development services before retiring the instance.

## Cutover verification

Flux and both pods were healthy on September 6, 2026. Public pages, database
APIs, admin login/logout and real analytics writes passed. The initial full R2
backup `personal-website-initial-20260906` completed at 100%. The volume is
`pvc-0e04a1f3-0e76-4432-86e8-e49023d7ce91`, currently degraded with one replica.
The old EC2 origin was `54.225.174.184`; Cloudflare tunnel configuration is v4.
