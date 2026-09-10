# Cosmotrak notifications

Separate notification backend and management application. Source is the private
`link2427/cosmotrak-notifications` repository. The application repository owns its
FastAPI/Jinja code, durable PostgreSQL worker, migrations, tests, OpenAPI contract,
fixtures, privacy rules and Apple setup instructions.

| Surface | URL |
| --- | --- |
| Installation API | https://api.cosmotrak.com/v1/ |
| OpenAPI | https://api.cosmotrak.com/v1/openapi.json |
| Fixtures | https://api.cosmotrak.com/v1/fixtures.json |
| Management | https://manage.cosmotrak.com |

The dedicated `flux-system/cosmotrak-notifications` Kustomization reconciles this
directory independently of unrelated application health. Do not add it to the
aggregate apps Kustomization. It decrypts SOPS Secrets using the existing age key.

API and worker use the same immutable image, including their migration init
containers. Update all four references together. Both workloads run non-root,
with read-only roots, dropped capabilities and no Kubernetes API token. Scheduling
prefers non-Atlas amd64 nodes while the existing storage incident is unresolved.
PostgreSQL uses a separate retained 5Gi `longhorn-resilient` claim with three
replicas, expansion enabled and daily `olympus-app-backup` R2 backup selection.
Do not prune or replace the claim during an app rollback.

`initial-backup.yaml` retains the first Snapshot and R2 Backup as deployment
evidence. The Snapshot was reconciled before the Backup because Longhorn's
admission check requires an existing snapshot. The backup completed September 9,
2026 at 06:22:30 UTC; it contains no registered recipients or delivery history.
Future data protection comes from the daily recurring job, not repeated creation
of this initial snapshot. A live `pg_dump` also passed a restore into an isolated
local PostgreSQL test database; a full R2 volume restore has not been exercised.

`application.secret.yaml` contains generated application/DB/SSO configuration.
`database.secret.yaml` provides the database password. `registry.secret.yaml` is
the namespace's encrypted authentication for the private GHCR image. Credentials
must never be printed or committed in plaintext. OIDC client fields also live in
Authentik's encrypted secret; its Flux-managed Cosmotrak blueprint permits only
the existing administrator account. Management sessions are verified by the app.
`OIDC_ADMIN_SUBJECT` in the application Secret pins that administrator's Authentik
user UUID, matching this provider's `user_uuid` subject mode. Both subject and
administrator email must match a valid signed identity; the provider's default
false email-verification claim does not grant or deny account ownership. Missing
subject configuration fails closed. Shared Authentik scope mappings stay intact.
Untrusted identity headers do not grant access. The public API hostname refuses
management routes, while management refuses installation API and metrics paths.

**General sends are disabled; explicitly targeted test campaigns are enabled.**
Separate Sandbox and Production APNs credentials are configured in the existing
application Secret: shared `APNS_TEAM_ID`, plus `APNS_SANDBOX_KEY_ID`,
`APNS_SANDBOX_PRIVATE_KEY`, `APNS_PRODUCTION_KEY_ID` and
`APNS_PRODUCTION_PRIVATE_KEY`. Each environment uses a distinct topic-specific
key, JWT cache and HTTP/2 connection pool. Never use a key from the other
environment as a fallback. Apple Developer ownership under team `4H3J77P7TR`
and Push Notifications for the existing identifier were verified September 10,
2026. Both new keys are restricted to their environment and the Cosmotrak topic.
Key metadata and verification evidence belong in the private operational handoff;
private key material belongs only in the encrypted Secret. Loaded credentials and
healthy deployments do not establish APNs acceptance or physical delivery.

Keep `DELIVERY_ENABLED=false` throughout physical verification. Only
`TEST_DELIVERY_ENABLED` is enabled for the controlled test window: that gate permits only
campaigns explicitly targeting one currently designated test installation, with
all consent and frequency checks retained. Set both flags false to pause all
sends. The app repo's `docs/device-verification.md` gives the exact test sequence.
The native
`COSMOTRAK_REMOTE_NOTIFICATIONS_ENABLED` release flag stays **NO** until deployed
contract checks and physical-device tests pass. The API topic for both native
platforms is `neel-industries.Cosmotrak`; widgets never register.

Cloudflare account `52018eaf0359596038f45ce3b2443891`, zone
`508ea866237e7780a349696c4341f945`, existing `olympus-access` tunnel
`3fb7dbb0-08b5-4003-895c-1c2c0ea858ca`. Both hostnames are proxied CNAMEs to the
tunnel and route to
`http://api.cosmotrak-notifications.svc.cluster.local:80`. Preserve all other
ingress rules when changing its remote configuration. No changes to the main
Cosmotrak website or SatelliteDataApi routes are needed.

Prometheus discovers the API's annotated internal metrics endpoint. The existing
Prometheus ConfigMap includes rules for target absence, stale worker heartbeat,
queue delay when sending is enabled, and APNs rejection/transport failures.
Prometheus currently has no Alertmanager destination; rules are visible in its
alerts UI. Do not claim email/push alert delivery. The queue and console also show
failures. Configuration changes require a Prometheus reload after the projected
ConfigMap updates.

Verify the dedicated Flux applied SHA, API/worker/Postgres rollout, public
health/contract, real Authentik sign-in, private-route rejection, internal metrics,
three healthy storage replicas and a completed R2 backup. Future app rollback
restores only the four image references to the previous verified digest and keeps
the namespace, storage and secrets. The initial deployment has no previous image:
take it offline by removing its two public ingress rules and scaling API/worker
to zero through GitOps while retaining PostgreSQL. Never remove the initial
Kustomization or namespace as an image rollback; namespace deletion can bypass a
PVC's Flux prune protection. Database migrations are a separate
recovery boundary: restore a verified backup into a new isolated volume with
sending disabled. Never downgrade or overwrite a live database to test recovery.
