# Olympus dashboard

Private dashboard: http://olympus-dashboard (Tailscale required).
Full hostname: http://olympus-dashboard.taild90e78.ts.net.
Existing LAN fallback: http://10.0.0.57:30080.

Homepage is pinned to v2.4.0 and its multi-architecture image digest. Configuration
lives in `config/`. Kustomize generates a content-addressed ConfigMap and rewrites
the Deployment volume reference, so every configuration edit rolls the pod and
refreshes its writable configuration copy. No manual rollout annotation is needed.
The startup probe warms the generated page and waits for the configured OLYMPUS
title before readiness can pass, keeping the image's bundled sample page out of
the first user request after a rollout. Update the probe if renaming the dashboard.
The dashboard is stateless; its config comes from Git and media credentials remain
in the existing SOPS-encrypted `homepage-media.secret.yaml`.

## Service inventory

The September 17, 2026 inventory includes public websites, Cosmotrak notifications
and data delivery, media automation, CI and development, all five compute nodes,
databases, background workers, Flux controllers, storage, and private/public
ingress components. Internal services have status cards without browser links
unless a usable access path already exists. Tailscale proxies and ephemeral Coder
workspaces are grouped; idle Actions runner pools scale to zero. Retired migration
helpers and the disabled legacy NFS provisioners are not active services.

Scheduled work is represented by its owning service: Coder catalog under Coder,
Satellite publishers under their status services, NetBox housekeeping under NetBox,
Forge import under Forge, and recurring backups under Longhorn. Satellite dev
ingestion is intentionally suspended. Dashboard probes only read existing status
and never start ingestion, builds, notification delivery, or backup jobs.

When adding a service, update `config/services.yaml` and, for a new group,
`config/settings.yaml`. Kubernetes cards require `app` to enable their status
indicator, plus `namespace` and `podSelector` using the actual live pod labels. Use
internal health URLs for server-side checks. Preserve existing access boundaries.
Media widget secrets must remain `HOMEPAGE_VAR_*` placeholders in config.

The VPN IP widget reads Gluetun's existing read-only public-IP endpoint. An empty
IP appears as `Not reported`; it does not imply that the tunnel is connected or
disconnected. Pod readiness separately reflects Gluetun's own health check.
This avoids requiring country/region fields when Gluetun has no IP metadata.

## Diagnosis and deployment

If the dashboard hostname fails, check `tailscale status` on the client first.
On September 17 the cluster application was healthy and the LAN URL returned 200,
but the Windows Tailscale client was stopped. Reconnecting it restored DNS and
dashboard access without a cluster restart.

Validate with `kubectl kustomize apps/olympus`, `kubectl kustomize
infrastructure/olympus`, and `git diff --check`. After publishing to main, reconcile
the `apps` Flux Kustomization and verify the Homepage rollout, `/api/healthcheck`,
`/api/services`, and all five browser tabs through Tailscale. Review media widgets
and cluster status after they finish loading.

Rollback by reverting the dashboard commit on main and reconciling `apps`.
There is no dashboard database or PVC migration to reverse.
