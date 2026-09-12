# Public database delivery

`data.cosmotrak.com` is an unauthenticated GET/HEAD service backed by the private
production R2 bucket. It serves exactly `/v1/manifest.json` and
`/v1/databases/<64-lowercase-hex-SHA256>.db`. Every other key and all write methods
are rejected. The Worker has no ingestion, storage credentials, timers or queues.
Private logs, release staging artifacts and bucket listings cannot be routed.

`configuration-rule.json` is the scoped Cloudflare configuration rule disabling
Browser Integrity Check only for GET/HEAD on this host's two route families.
The Worker still enforces the exact key allowlist. Other hostnames, methods and
WAF protections retain their existing settings. This is needed because BIC
otherwise rejects the publisher's Python client with error 1010 before the Worker.

The manifest requires revalidation; content-hash databases are immutable for one
year. Database bodies stream directly from R2 without byte transformation.
Native clients need no Cloudflare cookies, login, browser challenge or redirects.
Managed `r2.dev`, Workers development URLs and preview URLs remain disabled.

The versioned `wrangler.jsonc` is the edge configuration source of truth. Run
`npm ci`, `npm run types`, `npm run typecheck`, `npm test`, and `npx wrangler deploy --dry-run`
before `npm run deploy` with an authorized account. The initial deployment uses
the authenticated Cloudflare API with the same committed module and bindings;
retain the returned Worker version ID in the release record. Kubernetes publisher
and credential changes use the independent Flux Kustomizations, never direct apply.

The publisher verifies the immutable HTTPS download before conditionally moving
the manifest, then verifies the public manifest bytes. A failed destination is
retried from the saved candidate without another ingestion. AWS S3 remains the
compatibility delivery path for shipped clients.

Rollback removes the custom domain or restores a previously verified Worker
version. Do not enable bucket public access or expose arbitrary object paths.
Keep content-addressed databases and S3 compatibility objects for recovery.
