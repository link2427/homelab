# Monitoring recovery and storage

Prometheus uses the existing replicated `prometheus-data-longhorn` claim,
expanded to 20 GiB during the September 8, 2026 recovery. Retention is at most
30 days or 8 GiB, whichever is reached first. The conservative size cap leaves
room for WAL, compaction, and the preserved recovery archive. CPU can burst to
two cores; the prior half-core cap throttled WAL replay. The deployment uses
Recreate to avoid simultaneous TSDB writers, plus startup/readiness probes.
The image is pinned to the exact digest running before recovery.

The full filesystem also contained a damaged WAL segment that prevented
checkpoint creation and journal cleanup. A temporary init container moved the
old WAL and head chunks into `/prometheus/recovery-20260909` while Prometheus
was stopped. The init container was removed after verification. This archive
is about 6.2 GiB and must not be deleted without an explicit recovery decision.
A Longhorn snapshot, `prometheus-before-wal-repair-20260909`, was also verified
ready before repair. Existing persisted TSDB blocks were retained, subject to
the normal retention policy. Samples only in the archived journal are not
available in current queries; monitoring history has gaps from the outage.

The node-exporter job now targets all five current node addresses. The retired
10.0.0.106 address was removed. The existing annotated-pod discovery remains.

Rollback must preserve the expanded 20 GiB PVC: Kubernetes volumes cannot be
shrunk by reverting its requested size. Do not reintroduce the damaged WAL
into a running Prometheus process. Snapshot/archive recovery requires stopping
the sole writer and an explicit decision about which historical data to restore.

Reference: https://prometheus.io/docs/prometheus/latest/storage/
