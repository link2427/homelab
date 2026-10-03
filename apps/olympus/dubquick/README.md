# DubQuick

Public clip-to-game-pack service for `dubquick.com`. Source: private `link2427/autodub`; container: private `ghcr.io/link2427/dubquick`. App CI tests/builds `main`, publishes the image, then uses its dedicated homelab deploy key to pin the verified digest in `resources.yaml`. Flux performs the rollout.

## Deployment shape

- One `Recreate` replica, one application worker, eight queued jobs. SQLite, project metadata, and journals have a single writer process.
- CPU-only Atlas scheduling, 8 CPU/8 GiB requested, 32 CPU/24 GiB limited. No GPU allocation or change to Coder/Plex.
- Restricted pod security, read-only root, UID/GID 10001, no service-account token.
- `dubquick-state`: 5 GiB `longhorn-resilient`, prune-protected, daily `olympus-app-backup` with seven retained copies.
- `dubquick-scratch`: 30 GiB `longhorn-bulk`, prune-protected but deliberately unbacked because working media and models are rebuildable.
- Private R2 `dubquick-clips`: transient media only. App access expires at upload+72h; bucket lifecycle deletes objects/aborts multipart after three days. Accounts, purchases, scripts, and metadata remain on `/state`.
- `dubquick` ClusterIP, port80 → 8765; ingress allowed only from `authentik/cloudflared`, public HTTPS egress and cluster DNS allowed.

The intended remotely managed `olympus-access` tunnel route is `dubquick.com` → `http://dubquick.dubquick.svc.cluster.local:80`. Launch uses the application's Steam OpenID sign-in with no Steam API key, independently of the private Authentik policy. Steam's callback is `https://dubquick.com/api/auth/steam/callback`.

## Bootstrap status

Prepared October 2, 2026. The initial image is pinned to the verified application `main` release `9237034bc25adbbbd3983b1c376ee61548edaf5e` (`sha256:b40573ee6e60f98d6aefe6ec27a335cfbbb69c60deb5ef3edf5df36fb8b74dc2`). Cluster rollout and live acceptance are pending. Initial app CI publishes an image and emits a bootstrap notice if this manifest is absent from homelab; later releases update the existing image pin automatically.

The private R2 bucket exists with public access disabled and `dubquick-media-3-days` enabled. A generated session secret, dedicated bucket-only R2 credentials, and Stripe restricted runtime/webhook secrets are encrypted in `app.secret.yaml`. The current R2 credential is `DubQuick production media rotated`; the original setup credential was revoked after the replacement passed scoped checks. Actual R2 list/put/get/head and multipart create/abort checks passed; the temporary verification object was removed, and unrelated bucket access returned 403. The Stripe runtime key reads the three configured active live USD prices; forged webhook signatures are rejected. Never stage plaintext.

`dubquick-registry` is a namespace-scoped SOPS-encrypted `kubernetes.io/dockerconfigjson` Secret with its own `read:packages` credential. It expires December 31, 2026; rotate it before then to keep new pods and releases pulling successfully. Do not reuse another app's registry token. App repository Actions secret `HOMELAB_DEPLOY_KEY` is configured; it grants repository write access, while the reviewed workflow edits only the DubQuick image pin.

The DubQuick universal edge certificate is Active; enabling Always Use HTTPS and saving the prepared public tunnel route remain launch gates. Support forwarding is Active for `support@dubquick.com` to the owner's approved verified inbox, with catch-all disabled. DNS/tunnel exposure, Steam sign-in, application media flows, and Stripe webhook delivery must be verified before claiming launch.

## Verification and rollback

```powershell
kubectl kustomize apps/olympus/dubquick
kubectl kustomize apps/olympus
git diff --check
flux reconcile kustomization apps --with-source
kubectl -n dubquick rollout status deployment/dubquick --timeout=5m
kubectl -n dubquick get pods,svc,pvc
```

Check the actual applied Git revision and image digest, three healthy Longhorn state replicas, a completed state backup, public health/sign-in and an authorized sample import/export. Exercise cross-account denial and permitted/blocked network paths. Retention configuration alone does not prove elapsed deletion; observe a known test object's expiry without real customer media.

Rollback by reverting only the image pin in Git, then reconcile Flux. Preserve both claims and all backups. Database changes may need a separate compatible data restore; never delete the namespace or PVCs as an image rollback.
