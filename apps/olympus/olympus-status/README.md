# Olympus public status feed

Public API: <https://jacob-neel.com/api/olympus/v1/cluster>.
Source and consumer contract: [services/olympus-status](../../../services/olympus-status).
Consumer handoff: [INTEGRATION.md](../../../services/olympus-status/INTEGRATION.md).

The read-only feed discovers the cluster every 30 seconds. Two nonroot restricted
containers share a memory-backed snapshot volume. The collector alone receives a
rotating projected ServiceAccount token; its RBAC permits collection reads only.
The public Gunicorn process has no API token and mounts the snapshot read-only.
No persistent storage, database, external account or new secret is needed.

RBAC is cluster-scoped only for the inventory it must discover. Longhorn and Flux
reads use namespace Roles. Secrets, configuration, logs, exec and mutations are
not granted. Plain Flannel does not enforce NetworkPolicy, so no network isolation
claim is made. Public HTTP inputs are never used in collector requests.

## Delivery

`clusters/olympus/olympus-status.yaml` owns this directory independently of the
large `apps` Kustomization, matching newer applications. Do not add this directory
to `apps/olympus/kustomization.yaml` as a second owner.

`.github/workflows/olympus-status.yml` tests the source, builds and smoke-tests the
restricted container, pushes to GHCR and commits the verified digest for both
containers. Source/document changes trigger that pipeline automatically. The
initial image bootstrap occurs before the first resource commit. Runtime is
amd64; collected nodes can be any architecture.

```sh
python -m pip install jsonschema==4.25.1
python -m unittest discover -s services/olympus-status -v
kubectl kustomize apps/olympus/olympus-status
flux reconcile kustomization olympus-status --with-source
kubectl -n olympus-status rollout status deployment/olympus-status
```

The liveness probe checks collector progress independently from upstream health.
The server becomes Ready after its first successful inventory. Later API outages
preserve the last snapshot and serve it explicitly stale after 120 seconds; they
do not cause restarts or hide useful last-known information behind readiness.
Optional metrics/storage/GitOps failures produce a partial snapshot with nulls.
Inspect collector logs for source names only; upstream bodies/errors are not logged.

## Public routing

This uses the existing remotely managed `olympus-access` Cloudflare Tunnel. Insert
the following rule **before** the existing `jacob-neel.com` catch-all hostname rule:

```yaml
hostname: jacob-neel.com
path: ^/api/olympus(/.*)?$
service: http://olympus-status.olympus-status.svc.cluster.local:80
```

No DNS records, other tunnel routes, Access policies or website sources change.
This tunnel setting is managed via Cloudflare API, not Flux. Preserve the full
existing configuration when updating it. Path selection follows Cloudflare's
[documented first-match ingress rules](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/).

## Verification and rollback

Validate the public JSON against the shipped strict schema; check two different
`generatedAt` observations, empty `unavailableSources`, and the actual readiness
states. GET/HEAD should work, POST should return 405 and unknown paths 404. Confirm
the public container has neither the projected nor default ServiceAccount token.
Check collector RBAC denies Secrets and mutation verbs. `/uses` must still route
to the website and retain its current content.

For code rollback, restore both image pins from a known good Git revision and
reconcile this Kustomization. For public-route rollback, remove only the exact
`jacob-neel.com` + `^/api/olympus(/.*)?$` tunnel rule. The site's catch-all route
then handles that path as before. No user data or backup migration is involved.
Any later teardown/pruning of the namespace should be separately authorized.
