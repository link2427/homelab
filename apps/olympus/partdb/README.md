# Part-DB on Olympus

Part-DB 2.18.0 uses its official, digest-pinned image, one unprivileged replica,
and SQLite with foreign keys enabled. Database, attachments and public media
share a 5 GiB `longhorn-resilient` volume (three replicas, retained on removal).
Longhorn's `olympus-app-backup` job backs it up to R2 daily, retaining seven.
Migrations run before the web server and take a database backup before upgrading.

- Web: https://partdb.jacob-neel.dev
- Private MCP: http://olympus-partdb.taild90e78.ts.net/mcp (Streamable HTTP)
- Authentik SAML permits only `jacob.neel@gmail.com`, mapped to administrator.
- The bootstrap local administrator is disabled; anonymous inventory permissions
  are denied. App secrets and SAML signing keys are SOPS encrypted.
- MCP editing is enabled at the user's request. Clients should receive `Edit`
  scope, never `Admin` or `Full`. API tokens still require bearer authentication.
- MCP is denied on the public hostname by both Apache and Cloudflare Tunnel.
  Tailscale encrypts the private transport; no Funnel or public NodePort is used.

An independent Flux Kustomization owns this directory. Do not also add it to the
aggregate apps directory. Authentik's existing Helm release mounts
`../authentik/partdb-blueprint.yaml`.

Cloudflare uses the existing `olympus-access` tunnel. The exact Part-DB rules
must precede the existing `*.jacob-neel.dev` Coder rule:

```yaml
- hostname: partdb.jacob-neel.dev
  path: ^/mcp(/.*)?$
  service: http_status:404
- hostname: partdb.jacob-neel.dev
  service: http://partdb.partdb.svc.cluster.local:80
  originRequest:
    httpHostHeader: partdb.jacob-neel.dev
```

DNS is a proxied CNAME to
`3fb7dbb0-08b5-4003-895c-1c2c0ea858ca.cfargotunnel.com`.

Rollback by reverting the relevant Git commit and reconciling `partdb`.
Reverting an image does not undo database migrations: restore a verified backup
when required. Preserve the PVC and existing R2 backups. SAML SP certificate
expires September 2036; renew both its encrypted private key and Authentik's
public verification certificate together before expiry.
