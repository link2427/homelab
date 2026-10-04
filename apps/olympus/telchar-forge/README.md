# Telchar Forge

Flux manages this application from `resources.yaml`. Image changes require exact
immutable digests and verification of the API and authenticated analyst workspace.

## Design and writing release, October 4, 2026

The application images and scheduled static importer are pinned to published Forge
commit `8cc411c6de96b06cf60df22de145f89c927c4a98`, including the white Telchar design,
rewritten application/site copy and Imago `v2026.10.04.1` screenshots. The successful
publication run is `Telchar-Dynamics/Forge` Actions `37196448509`.
Schema remains 061; this release changes no database, storage, secret, routing or
workspace-switch configuration. Previous exact digests remain in Git for rollback.
Verify Flux reconciliation, all nine Deployments, public app/site paths and the
authenticated workspace. The static importer takes its new image on its next scheduled
run; this update does not trigger an import. The detailed receipt lives in Forge's
`docs/deployment/DESIGN-WRITING-2026-10-04.md`.

## PostgreSQL memory, October 4, 2026

Evidence reads exhausted the previous 4 GiB cgroup's page cache while the database
used the default 128 MiB shared buffer pool. Shared Longhorn storage also showed
high I/O latency. PostgreSQL now requests 3 GiB and allows 8 GiB, with 2 GiB shared
buffers, a 6 GiB planner cache estimate and a 2 GiB WAL target. Per-operation
`work_mem` remains at 4 MiB. This protects a larger working set without multiplying
per-query allocations. Verify query latency and memory after cache warmup; it does
not repair the underlying Atlas storage issue.

The existing `forge-postgres-longhorn` claim, image, amd64 capability selector and
three-replica policy are retained. The October 4 scheduled database backup was
Completed before this change. Rollback is a Git revert of the PostgreSQL arguments
and resource changes followed by Flux reconciliation; preserve the claim and data.
