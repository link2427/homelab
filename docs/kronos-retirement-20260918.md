# Kronos retirement — September 18, 2026

The intended topology is one control plane on `optiplex-hermes`, with Atlas,
Precision 5810 and Precision 7810 as workers. The Pis are outside the cluster.

The original August migration notes recorded the Pi control plane as retired.
Kronos registered again on August 6 and still had a Talos `controlplane` machine
configuration. Its later power/configuration history could not be established.
Do not treat removing a Kubernetes Node object or powering off a machine as a
permanent retirement: a machine with its existing configuration can register again.

## Verified before removal

- Hermes and Kronos were the only two voting etcd members. Both were healthy and
  caught up; Kronos was leader. Hermes' API server, scheduler and controller
  manager were Ready. The management/control-plane endpoint was already Hermes.
- Kronos had only control-plane static pods and infrastructure DaemonSets. No
  persistent volume node affinity referenced it, and no application migration
  was required.
- Talos identified its actual system disk as the 128-GB `mmcblk0` SD card, with
  STATE on partition 5 and EPHEMERAL on partition 6. Its old install-disk setting
  named `/dev/sda`; the discovered running system disk was checked explicitly.
- The Pi had no `talos.config` boot argument that would fetch its old configuration
  again after reset.
- An etcd snapshot and both machine configurations were encrypted on the management
  workstation using the existing age recipient. Snapshot metadata and decryption
  checks passed. Private recovery paths and receipts are in operational notes;
  no snapshot, configuration credentials or secret values are in this repository.

## Retirement performed

1. Transferred etcd leadership from Kronos to Hermes and confirmed replication.
2. Gracefully reset **Kronos only**, selecting its system-disk STATE and EPHEMERAL
   partitions and shutdown rather than reboot. This drained the node, removed its
   etcd membership and cleared the configuration/runtime state needed to rejoin.
3. Confirmed Hermes was the sole voting etcd member and leader, then deleted the
   exact retired Kubernetes Node object.
4. Removed Kronos from Homepage's active fleet and Prometheus' static scrape targets.
   Updated the public feed's integration notes; its inventory updates automatically.

The Talos CLI returned success for the graceful reset sequence. The remaining
four nodes and Hermes' Kubernetes API stayed healthy during the operation.
The Pi may be physically unplugged after this retirement. A future reuse should
start with a deliberately chosen fresh machine configuration, not the archived
control-plane configuration.

## Recovery and availability

Hermes is now the single point of control-plane availability, as explicitly chosen.
Keep its etcd backups available outside the cluster. Node/machine retirement is
not reversed by a Git revert; restoring an etcd snapshot is a disaster-recovery
operation, not a routine way to add the Pi back.

The procedure follows the Talos 1.12 documentation for
[scaling down the control plane](https://docs.siderolabs.com/talos/v1.12/learn-more/control-plane#scale-down-the-control-plane)
and [resetting selected system partitions](https://docs.siderolabs.com/talos/v1.12/configure-your-talos-cluster/lifecycle-management/resetting-a-machine).
