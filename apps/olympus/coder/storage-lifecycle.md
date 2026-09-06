# Coder storage lifecycle

New workspace homes use `coder-fast` (two fast replicas), `coder-resilient`
(three storage replicas), or `coder-bulk` (one bulk replica). These classes use
`Delete`; durable application classes remain `Retain`.

- Stop/restart: the home PVC is independent of `start_count`, so files survive.
- Delete workspace: Terraform deletes the home PVC; Kubernetes/Longhorn delete
  its PV and local replicas. Export needed files or verify a completed backup
  before deletion. There is no automatic final backup on deletion.
- Backups: daily at 04:00 UTC, three retained per workspace volume in R2.
  Existing backups remain after local volume deletion. Do not delete Longhorn
  Backup or BackupVolume resources as part of local disk cleanup.
- Builder cache: Container Forge uses disposable `emptyDir`; no persistent
  Longhorn builder-cache claim is needed.
- Existing homes: Terraform `ignore_changes = all` preserves their original
  storage class and policy. Do not replace a working PVC to adopt the new class.

## Why old storage accumulated

The original templates used general-purpose `Retain` storage classes. Deleting
a workspace removed its pod and PVC, but left a Released PV and its Longhorn
volume. Test workspaces, deleted development workspaces, old builder caches,
and a manually mounted recovery copy accumulated without a retirement step.
Longhorn schedules against requested volume capacity per replica, so even sparse
volumes blocked new replicas while the physical disks still had free space.

## Review and cleanup

1. Match each claim's workspace UUID against Coder. A stopped workspace is live
   data; only an explicitly deleted workspace is a cleanup candidate.
2. Check all PVCs and pod mounts, PV phase/UID, CSI volume handle, Longhorn
   attachment, and replica nodes. Record exact targets in private AI context.
3. Verify completed off-site backups for valuable homes. Caches may be discarded.
   An offline disk's reported size is stale, not proof that a home is empty.
4. For an approved Released PV, change only that PV's reclaim policy to `Delete`
   and let the CSI controller remove it. Recheck UID and phase immediately before
   the change. Do not remove finalizers to force cleanup.
5. Retire temporary recovery pods and claims once their data is preserved. Keep
   the source backup URL and restore instructions in private context.
6. Verify surviving workspace/database health, replicas, off-site backups, and
   actual disk free space. Report logical allocation separately from bytes freed.

September 6 cleanup removed 24 Released Coder volumes and one read-only recovery
copy, preserving the sole active workspace and Coder PostgreSQL. Backup URLs,
resource UIDs, before/after measurements, and recovery metadata are recorded in
the gitignored Homelab AI context. Files on the offline 7810 cannot be physically
verified or reclaimed until that node returns; compare any later orphan replicas
against the recorded retired-volume inventory before deleting them.

After automatic replica rebuilding, online SSD use fell from about 390 GiB to
273 GiB out of 1,166 GiB, leaving 894 GiB free. Scheduled replica allocation fell
from 1,020 GiB to 517 GiB. The active Coder home regained two healthy replicas;
the personal website database regained three. Offline HDD figures are excluded.

All five active templates were published and their downloaded source verified.
A disposable 1 GiB claim preserved a file across pod replacement, then its PVC
deletion automatically removed the PV and Longhorn volume. Test resources were
removed. No production workspace was restarted to perform this verification.
