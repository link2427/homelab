# Cosmotrak

Public website at https://cosmotrak.com. The source repository is
`link2427/Cosmotrak-Website`; pushes to its main branch run lint, type checks,
rendered-page tests and a restricted-container smoke test. GitHub Actions
publishes a GHCR image and updates only this deployment's immutable image pin
using a dedicated homelab SSH deploy key.

A dedicated `flux-system/cosmotrak` Kustomization owns these resources, registered
in `clusters/olympus/cosmotrak.yaml`. It uses only built-in Kubernetes resources
and needs no storage or operator dependency. It reconciles independently of the
aggregate infrastructure and apps health checks, so an offline node or unrelated
Plex or monitoring failure cannot delay website releases. Do not add this directory to the
aggregate apps Kustomization.

The stateless Node service uses no database, persistent storage, Kubernetes API
access, or application secrets. It runs non-root with a read-only root filesystem.
`/healthz` reports the running source revision.

`/status` is the public satellite-data status page. Its same-origin `/api/status`
route reads only the internal production service through `SATELLITE_STATUS_URL`.
The server exposes an allowlisted health summary, with bounded requests and
`Cache-Control: no-store`. It needs no storage credentials and never starts an
update. Dev has no public route. Data-health failures must not change the website's
process probes. See the website's `docs/service-status.md` for behavior and tests.

Cloudflare account: `52018eaf0359596038f45ce3b2443891`.
Zone: `508ea866237e7780a349696c4341f945` (`cosmotrak.com`).
The existing remotely managed `olympus-access` tunnel
(`3fb7dbb0-08b5-4003-895c-1c2c0ea858ca`) routes the apex and www hostnames to
`http://cosmotrak.cosmotrak.svc.cluster.local:80`. Both DNS records are proxied
CNAMEs targeting that tunnel's `.cfargotunnel.com` hostname. The site redirects
www to the apex. Tunnel routing is managed in Cloudflare; Kubernetes resources
are managed by Flux. Preserve all other tunnel ingress rules when updating it.

Verify with `kubectl -n cosmotrak rollout status deployment/cosmotrak`,
`kubectl -n cosmotrak get pods,svc`, and HTTPS requests to `/`, `/privacy`,
`/support`, `/credits`, `/healthz`, `/robots.txt`, `/sitemap.xml`, and `/og.png`.
Rollback by reverting a homelab image-pin commit and reconciling Flux.
