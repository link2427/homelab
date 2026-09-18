# Olympus live cluster feed — integration handoff

The existing `/uses` page has **not** been changed. This service supplies its live
cluster section. Personal hardware stays in the website's static inventory.

## Endpoints

Base: `https://jacob-neel.com/api/olympus/v1`

| Path | Response |
| --- | --- |
| `/cluster` | Current public cluster snapshot, JSON |
| `/schema.json` | Strict JSON Schema 2020-12 contract |
| `/types.ts` | Copyable TypeScript interfaces |
| `/integration` | This document |

All endpoints accept GET and HEAD only. No credentials, API keys, or cookies are
needed. CORS permits public reads from any origin, including website previews.
Queries do not control discovery. There is no proxy endpoint or write operation.
Polling the feed never triggers Kubernetes or Prometheus requests.

## What updates automatically

- Node membership, Ready condition, architecture, Talos and Kubernetes versions,
  logical CPU capacity, memory, allocatable resources and GPU scheduling units.
- Hardware manufacturer/model from node-exporter DMI metrics, when available.
- Node CPU and memory working-set usage from metrics-server, with measurement time.
- All Deployment, StatefulSet and DaemonSet controllers, including future additions,
  with desired/ready replicas and rollout-aware readiness. A namespace supplies
  the service grouping; new namespaces fall into `Services` automatically.
- CronJob inventory, suspended/active state and last successful completion time.
- Active/Ready pod counts, Longhorn physical disk totals and Flux readiness.

Temporary Coder workspaces/builders are grouped without UUIDs. Tailnet proxies and
Longhorn engine versions are grouped. Retired `atlas-migration` and
`nfs-provisioner` namespaces are excluded. Annotating a controller or CronJob with
`status.olympus.dev/visibility: private` hides that item's metadata; cluster-wide
pod and capacity counts still include it. This is an opt-out for metadata, not a
policy that removes the workload from every aggregate.

New service names become public automatically. The output is a fixed projection:
it never includes pod names, IPs, internal URLs, serial numbers, arbitrary labels,
annotations, container images, registry/repository paths, environment variables,
Secrets, logs, command arguments, mounts, or upstream error text. `publicUrl` is
only set for explicitly approved public links; null means render a non-link card.

## Freshness and health rules

Collection runs every 30 seconds. Snapshots expire after 120 seconds. Successful
responses may be cached for at most 15 seconds (less near expiry) and include an
ETag. Respect normal browser caching or send `If-None-Match` from server clients.

Always show the timestamp. Treat data as stale if **either** `stale` is true
**or** `Date.now() >= Date.parse(expiresAt)`. On fetch errors retain previous data
only as a clearly labeled last observation. Never leave an old green status live.
There is no history, uptime percentage or incident log in v1.

| Condition | Required presentation |
| --- | --- |
| Fresh, complete snapshot | Render current observations |
| `partial: true` | Indicate limited telemetry; null means unavailable, never zero |
| Expired snapshot | Show “Last observed … / updates unavailable”; suppress live green states |
| HTTP 503 | No initial snapshot; show unavailable and retry after 30 seconds |
| Network error / 502 / 504 | Feed unavailable; do not infer that every service is down |

`cluster.status` summarizes node/controller readiness, Flux, and disk readiness.
It is **not** an external reachability test or a guarantee that an application's
business functions work. `healthy` service means the controller has observed its
generation and has the desired ready, available and updated replicas. `paused`
means desired replicas are zero. `degraded` includes rollouts and unhealthy
replicas. `unknown` means current readiness cannot be confirmed. A stale response
forces overall status to `unknown`; per-item values are then last-known values.

Optional telemetry failures produce `partial: true`, list failed sources in
`unavailableSources` and omit their measurements with null. Missing/stale metrics
on individual nodes also make the snapshot partial. Aggregate usage is null unless
every node has fresh CPU and memory readings; `measuredNodes` gives coverage.
If a core inventory read fails, the previous snapshot ages normally instead of
publishing an incomplete inventory as if services were deleted.

## Resource interpretation

- CPU means logical cores/threads as advertised by Kubernetes, not physical sockets.
  CPU percentage is usage divided by that node's capacity. It is not a benchmark.
- Memory is bytes; divide by `1024 ** 3` for GiB. Reported capacity is OS-visible
  memory, which can be slightly less than installed DIMM capacity.
- `gpuSchedulingUnits` is Kubernetes `nvidia.com/gpu` capacity. MPS or time slicing
  can inflate that number. Do **not** label it physical GPUs, VRAM or TFLOPS.
  GPU model, VRAM and utilization are not currently available from a live exporter.
- Storage is the sum of Longhorn-managed backing filesystems, including filesystem
  space used by the OS/other files. It excludes Atlas NAS DATA-2 and other unmanaged
  disks. It is not replicated usable capacity and must not be added to PVC sizes.
- `activePods` excludes terminal and terminating pods, and can include job pods.
  Pod counts and controller replica counts are different measures.
- Scheduled jobs are observations, not backup integrity or freshness guarantees.
  `lastSucceededAt` says Kubernetes observed success, not that a backup was restored.

## SvelteKit integration sketch

Copy `types.ts` to the website's `src/lib/types/olympus.ts`. Fetch on the client
so building or server-rendering `/uses` does not depend on a healthy homelab.
This is an example for the other agent to adapt, not a change to the website:

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import type { ClusterFeed } from '$lib/types/olympus';

  let feed: ClusterFeed | null = $state(null);
  let unavailable = $state(false);
  let clock = $state(Date.now());
  const stale = $derived(!feed || unavailable || feed.stale || clock >= Date.parse(feed.expiresAt));

  onMount(() => {
    let stopped = false;
    let inFlight: AbortController | null = null;
    async function refresh() {
      if (document.hidden || inFlight || stopped) return;
      const controller = new AbortController();
      inFlight = controller;
      const timeout = setTimeout(() => controller.abort(), 8000);
      try {
        const response = await fetch('/api/olympus/v1/cluster', {
          signal: controller.signal, credentials: 'omit'
        });
        if (!response.ok) throw new Error('Feed unavailable');
        const next: ClusterFeed = await response.json();
        if (next.schemaVersion !== '1.0' || !Array.isArray(next.nodes) ||
            !Array.isArray(next.services) || !Number.isFinite(Date.parse(next.expiresAt))) {
          throw new Error('Unsupported feed');
        }
        if (!stopped) { feed = next; unavailable = false; }
      } catch {
        if (!stopped) unavailable = true;
      } finally {
        clearTimeout(timeout);
        inFlight = null;
      }
    }
    void refresh();
    const polling = setInterval(refresh, 60_000);
    const ticking = setInterval(() => clock = Date.now(), 1000);
    const visible = () => { if (!document.hidden) void refresh(); };
    document.addEventListener('visibilitychange', visible);
    return () => {
      stopped = true;
      inFlight?.abort();
      clearInterval(polling);
      clearInterval(ticking);
      document.removeEventListener('visibilitychange', visible);
    };
  });
</script>

<!-- Render feed.nodes and feed.services by stable id; gate live badges on !stale. -->
```

For local development or a preview host use the absolute production URL instead
of the relative fetch URL. Display service/node names as text, never raw HTML.
The JSON Schema is the full validation contract; the example guard is deliberately
small. Prefer runtime schema validation at an application boundary when available.

## Handoff for the `/uses` redesign

Source inspected: `link2427/Personal-Website`, `src/routes/uses/+page.svelte` and
`src/lib/components/LabTopology.svelte`. The old topology and hardware lists are
static and describe a previous cluster. `/api/monitor/[host]` is a legacy endpoint
with hardcoded node-exporter addresses; it is unnecessary for this integration.

Build a live **Olympus** section from this feed and a separate static **Personal
hardware** section for the MacBook, main PC, spare/offline Pis and spare GPUs.
The Pis are outside the active cluster. Kronos was retired on September 18, 2026;
Hermes is the sole control plane, with Atlas and both Precision systems as workers.
Use the feed's current node list rather than hardcoding that inventory. Keep retired
and offline Pis in the static personal inventory without adding their capacity to
cluster totals. Confirm their physical RAM before reusing old 8-GB descriptions:
Kronos reported approximately 4 GB OS-visible memory before retirement.

Derive cluster totals from `summary`, node cards from `nodes`, and software/service
groups from `services`. Derive topology membership from node IDs; the feed does
not claim physical cable connections or expose network addresses. Keep editorial
descriptions, ownership, photographs and personal workstation specifications local.
Remove the mixed CPU/GPU TFLOPS sum as a live cluster metric; this feed makes no
such performance claim. Use observed CPU/memory activity instead.

This service lives at `services/olympus-status` in `link2427/homelab`.
No application-source changes or personal-hardware edits are included in this delivery.
