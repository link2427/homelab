# Cosmotrak

Public website at https://cosmotrak.com. The source repository is
`link2427/Cosmotrak-Website`; pushes to its main branch run lint, type checks,
rendered-page tests and a restricted-container smoke test. GitHub Actions
publishes a GHCR image and updates only this deployment's immutable image pin
using a dedicated homelab SSH deploy key.

A dedicated `flux-system/cosmotrak` Kustomization owns these resources, registered
in `clusters/olympus/cosmotrak.yaml`. It depends on infrastructure and reconciles
independently of the aggregate apps health checks, so unrelated Plex or monitoring
failures cannot delay website releases. Do not also add this directory to the
aggregate apps Kustomization.

The stateless Node service uses no database, persistent storage, Kubernetes API
access, or application secrets. It runs non-root with a read-only root filesystem.
`/healthz` reports the running source revision.

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
