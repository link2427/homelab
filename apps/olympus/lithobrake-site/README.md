# Lithobrake site

Coming-soon site for Lithobrake: Spaceflight Simulator at `lithobrakegame.com`.
Initial release: site commit `44b1899`, image
`sha256:1377f9bda10ff73d98f0ac8d5d2ce2237503d02b3b1a6e19e6971d1d44524592`.
Source: private `link2427/lithobrake-site` (Next.js static export). Image:
`ghcr.io/link2427/lithobrake-site`, built and smoke-tested by that repo's `Image`
workflow on every push to `main`. The workflow prints the published digest; pin it
in `resources.yaml` through a PR here. There is no automatic pin update yet.

The image holds only the public site, so it is pulled without credentials: the GHCR
package must be **public** (GitHub → Packages → lithobrake-site → Package settings →
Change visibility). While it is private, pods sit in `ImagePullBackOff` and this
Kustomization reports not Ready; nothing else is affected. The alternative is a
namespace-scoped SOPS `registry.secret.yaml` with its own `read:packages` token, as the
other apps use.

## Deployment shape

- Two interchangeable replicas of unprivileged nginx (UID 101) serving static files,
  spread across nodes. Restricted pod security, read-only root, writable `/tmp`
  `emptyDir` only, no service-account token, no service links.
- No state, no PVC, no Secret.
- `lithobrake-site` ClusterIP, port 80 → 8080. `/healthz` answers `ok` for probes.
- NetworkPolicy: ingress only from `authentik/cloudflared` on 8080; no egress at all.
- Independent Flux Kustomization `lithobrake-site` (`clusters/olympus/lithobrake-site.yaml`)
  owns this directory, so a failed rollout here cannot hold the aggregate `apps`
  Kustomization unhealthy. Do not also add it to `apps/olympus/kustomization.yaml`.

## Public access

Remotely managed tunnel `olympus-access` (`3fb7dbb0-08b5-4003-895c-1c2c0ea858ca`):
`lithobrakegame.com` and `www.lithobrakegame.com` →
`http://lithobrake-site.lithobrake-site.svc.cluster.local:80`, placed before the
catch-all. Proxied CNAMEs for the apex and `www` point at
`3fb7dbb0-08b5-4003-895c-1c2c0ea858ca.cfargotunnel.com`. nginx redirects `www` to the
apex. The site has no login and serves only public pages, so it is not behind
Authentik.

Planned, not built: a Listmonk launch-news list on the same hostname by tunnel path
rule. See `docs/email-signup.md` in the site repository.

## Verification and rollback

```powershell
kubectl kustomize apps/olympus/lithobrake-site
git diff --check
flux reconcile kustomization lithobrake-site --with-source
kubectl -n lithobrake-site rollout status deployment/lithobrake-site --timeout=5m
kubectl -n lithobrake-site get pods,svc
curl -sI https://lithobrakegame.com/
```

Roll back by reverting the image pin in Git and reconciling Flux. Nothing here holds
data, so a rollback never needs a restore.
