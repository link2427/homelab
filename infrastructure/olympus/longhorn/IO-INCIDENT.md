# Atlas storage contention — September 9, 2026

Large workspace image unpacks repeatedly caused Longhorn replica I/O timeouts
on Atlas. CPU, memory, free space, and node readiness were adequate. A single
unpack reproduced the problem with the recovery clone detached. Concurrent
image pulls are therefore not the only trigger.

The initial sample showed sdb at 100% busy, about 75 MB/s writes, 2.6 seconds
mean write latency, and roughly 70% full I/O pressure. Replica operations
exceeded their eight-second timeout. Healthy remote replicas continued serving
affected volumes; no entire volume became faulted during these observations.
The original Coder workspace remained on its existing build and pod with zero
restarts. Healthy snapshots after recovery do not establish safe behavior under
the same load.

## Retained mitigation and rollout hold

`rebuild-settings.yaml` limits simultaneous replica rebuilds to one per node,
reducing competing recovery work. Replica counts and storage layout are
unchanged. The existing Coder cache has the verified image on all four compute
nodes, so current canary restarts do not require a cold pull.

Keep Coder's `publisher/images.json` promotion gate false. This also holds
scheduled workspace image rebuilding during the initial rollout. Harness
release checks and repository catalog refreshes continue independently. Do not
clear the storage blocker solely because an idle 24-hour canary remains healthy.
Avoid further large unpack benchmarks while the underlying issue is unresolved.

## Rejected trials and restored configuration

A bounded BFQ scheduler trial reproduced replica failures after about 48
seconds. A separate containerd write limit of 16 MiB/s and 512 write IOPS reduced
observed traffic to about 5.5 MiB/s and 461 IOPS but still reproduced failures
after 101 seconds. The latter reused partial image cache and was not a completed
cold-pull benchmark. Both clients were canceled when failures appeared; delayed
failures and replica recovery continued afterward. Neither trial is a fix.

Both changes were rolled back without a reboot. The live Talos `machine.sysfs`
configuration explicitly restores:

```yaml
machine:
  sysfs:
    block/sdb/queue/scheduler: mq-deadline
    fs/cgroup/podruntime/runtime/io.max: "8:16 rbps=max wbps=max riops=max wiops=max"
```

Verify the actual scheduler and cgroup file after a Talos configuration change;
application is asynchronous. The kernel may display the unlimited `io.max` as
empty. Deleting the scheduler key restored the wrong selection in an earlier
trial, so use the explicit original value. No temporary Talos try remains active.

The CRI daemon uses `/podruntime/runtime`; Longhorn and workspace processes use
separate `/kubepods` cgroups. The trial did not impose a workload I/O limit.
See [Linux I/O controls](https://cdn.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
and [Talos machine configuration](https://docs.siderolabs.com/talos/v1.12/reference/configuration/v1alpha1/config)
for the control semantics.

## Unresolved diagnosis

Atlas sdb reports a 500 GB, nonrotational, RAID0 logical device in write-through
mode, WWID `naa.600508b1001ccc3727510b6fbcfa400f`. The inspected kernel log did
not show a matching medium error or controller reset. These observations do
not establish physical drive or RAID controller health. Physical drive,
controller, and cache-protection diagnostics remain outstanding. Do not enable
volatile write cache, repurpose another disk, or reduce replicas as a shortcut.

Recover all replicas and resolve the storage limitation before validating
future image rotation under load and allowing Coder production promotion.
