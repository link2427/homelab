# ShaderWeave

Public origin: https://shaderweave.com. Application source is the private
`link2427/shaderweave` repository. Flux independently owns this directory through
`clusters/olympus/shaderweave.yaml`; do not also include it in the aggregate apps.

The web ClusterIP `shaderweave-web.shaderweave.svc.cluster.local:80` is the
Cloudflare Tunnel origin. The web server proxies `/v1/*` to the internal API on
3001. OAuth, API, MCP and Stripe webhook routes use application authentication;
they must not receive an additional interactive Access/Authentik challenge.
Hosted mode is mandatory (`SHADERWEAVE_LOCAL_MODE=0`). No local API keys or
development identity are provisioned in production.

## State and recovery

One API replica uses Recreate and RWO SQLite storage. Keep this single writer.
The API image contains the CPU renderer and FFmpeg, with two render workers and
one asynchronous job at a time. No GPU or separate render deployment is needed.
SQLite, sessions, presets, API keys and the credit ledger use a 4 GiB
longhorn-resilient PVC. Results use 8 GiB longhorn-fast. Both claims have Flux
prune protection and the Olympus application backup labels. Results expire
after seven days, with a five-GiB output limit. Cache and temporary render files
use bounded ephemeral storage.

Production starts fresh; local development data and its nine existing jobs
remain on the workstation. Do not copy an actively written SQLite database or
assign the shared local identity to a customer. Application migration backups
and Longhorn/R2 backups must be retained when rolling back releases.

## Delivery

Every main push in the application repository runs frozen installs, unit tests,
lint, type checks, browser tests and hardened container checks. Only the tested
image pair is published to GHCR. A dedicated Homelab deploy key then updates both
immutable image pins in one commit. Flux applies main; the workflow waits for
the matching web and API revision through public health endpoints. Older runs
skip deployment after a newer main revision exists. PRs use hosted runners;
trusted main builds use `olympus-linux` and the cached Olympus builder.

The deployment key is only in ShaderWeave Actions secrets (`HOMELAB_DEPLOY_KEY`),
GitHub Homelab deploy-key ID 162565334. CI receives no Kubernetes credentials.
The namespace's `shaderweave-registry` SOPS secret has only read:packages access.
Its dedicated GitHub token (ID 5402204857) expires December 6, 2026; renew it
before expiry and update the encrypted registry secret. Never make private
application images public to work around pull failures.

Rollback by reverting the relevant pair of image pins in Homelab main and
waiting for the ShaderWeave Flux Kustomization. Use schema-compatible images.
A Git revert does not reverse migrations or payment events; restoring the
database requires separately reconciling payments received since the backup.

## Identity and billing

Google project: `rugged-cooler-507917-t8` (ShaderWeave).
GitHub OAuth application: 3843105 (ShaderWeave).
Callbacks: `https://shaderweave.com/v1/auth/callback/google` and
`https://shaderweave.com/v1/auth/callback/github`.
Credentials and a dedicated random Better Auth secret are SOPS encrypted in
`env.secret.yaml`; only the API receives them.

Stripe account: `acct_1UCtDUQ1a8tKTJjx` under Neel Industries. Reuse the existing
catalog in the ConfigMap; never recreate prices during each deployment.
Webhook: `https://shaderweave.com/v1/billing/webhook`.
See the source repository's `docs/BILLING-OLYMPUS.md` for the event list,
idempotent setup command, credit model and financial recovery constraints.
Live account activation and final billing verification are tracked in private
operational notes; do not interpret deployed pods alone as payment readiness.

The dedicated live restricted key and webhook signing secret are encrypted in
`env.secret.yaml`, together with portal configuration
`bpc_1UD95qQ1a8tKTJjx22Cpelgl`. The key permits customer, Checkout and customer
portal writes, and charge/refund, product, price, invoice and subscription reads.
It has no payout, bank-account, credential-management or webhook-management
permissions. Provisioning the catalog or webhook is an operator action, not a
runtime permission or deployment step.

Webhook destination `we_1UD92tQ1a8tKTJjxfAzCRXxS` uses API version
`2026-08-26.dahlia` and the application's nine billing events. Automatic tax
remains disabled until applicable registrations are configured. Change the API
pod's billing-config-revision annotation when rotating the encrypted credentials
so Flux rolls the process onto the new values.
