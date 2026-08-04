# Hermes Agent future deployment design

Status: **design only — not approved for implementation**

This document records the proposed future home for Hermes Agent on Olympus. It
does not describe deployed infrastructure. Do not install KubeVirt, create the
VM, restore the former Atlas Hermes data, or change cluster networking until a
future implementation is explicitly requested.

The previous Hermes installation on Atlas was intentionally deleted during the
Atlas Talos migration. It should not be restored. A future installation should
start clean while retaining the Aedile repository as useful configuration and
design context.

## Goals

- Keep Hermes available continuously rather than tying it to a disposable
  development session.
- Let Hermes run arbitrary commands, install software, use a headless browser,
  and modify anything inside its own container.
- Prevent routine agent activity from reaching or administering Talos,
  Kubernetes, Longhorn, the NAS, or other trusted LAN services.
- Persist Hermes configuration, memory, sessions, skills, repositories, and
  exported artifacts across process, container, VM, and node restarts.
- Make recovery reproducible through Flux, Longhorn, SOPS, and R2 backups.
- Keep the deployment small and headless until a real desktop-control use case
  exists.

No isolation mechanism can guarantee that arbitrary code will never escape.
The design therefore uses several boundaries and assumes each individual one
could eventually fail.

## Chosen architecture

```text
Olympus / Talos
└── KubeVirt VM: aedile-hermes
    ├── Minimal Ubuntu or Debian guest
    ├── Root-owned guest firewall
    ├── Unprivileged service account
    ├── Rootless Podman
    │   └── Official Hermes Agent container
    ├── Longhorn operating-system disk
    ├── Longhorn Hermes data/workspace disk
    └── Tailscale-only management access
```

The VM should be permanent infrastructure managed by Flux, not a Coder-owned
workspace. Coder remains the platform for user-created development workspaces.
The Coder interface is pleasant, but coupling an always-on gateway to Coder's
start, stop, update, and delete lifecycle adds unnecessary failure and deletion
paths. A Coder agent could be added to the VM later, but is not required.

KubeVirt and CDI are not currently installed. All four Olympus machines were
confirmed to expose `/dev/kvm`, so hardware virtualization appears feasible,
but a future implementation must repeat the full compatibility and capacity
checks before installing cluster-wide virtualization components.

## Initial resources

Start conservatively:

| Resource | Initial value |
| --- | ---: |
| vCPU | 2 |
| Guest memory | 4 GiB |
| OS disk | 25 GiB |
| Hermes data/workspace disk | 30 GiB |
| GPU | none |

Hermes officially recommends two CPU cores and 2–4 GiB of memory. Headless
Chromium is expected to be the largest routine memory consumer. Increase the
guest to 6 GiB only if measurements show browser-related pressure or OOM kills.
The VM may prefer Atlas but should not require Atlas unless a later workload
creates a genuine placement need.

Use a two-replica Longhorn class for the persistent data disk and include it in
the normal R2 recurring-backup policy. Keep the data disk separate from the OS
disk so the guest can be rebuilt without losing Hermes state. Final disk sizes,
StorageClasses, backup labels, and retention must be checked against available
Longhorn capacity immediately before implementation.

## Container freedom and isolation boundary

Hermes should be operationally unrestricted inside its container. It should be
able to:

- Execute arbitrary shell commands and programs.
- Write anywhere in its container filesystem.
- Install operating-system, Python, Node.js, and other userland packages.
- Run background processes and development servers.
- Clone and modify authorized repositories.
- Use Chromium and Playwright.
- Access explicitly permitted public Internet services.

The container must not receive privileges that weaken its boundary:

- No `--privileged` mode or `CAP_SYS_ADMIN`.
- No host PID, IPC, or network namespace.
- No Docker or Podman daemon socket.
- No Kubernetes ServiceAccount token, kubeconfig, Talos configuration, or Flux
  credentials.
- No host devices, GPUs, NAS mounts, Longhorn mounts, or broad guest-directory
  mounts.
- No Cloudflare, Tailscale administration, or cluster administration tokens.

Run the official Hermes image through rootless Podman under a dedicated guest
user. Hermes may act as root inside the container, but that identity should map
to an unprivileged guest user. Use Hermes' local terminal backend so commands
run freely inside the already-isolated Hermes container; do not mount a
container-engine socket to create nested execution containers.

Persist `/opt/data` and a dedicated `/workspace` on the data disk. Treat the
rest of the container layer as replaceable. Common permanent tools should
eventually move into a small derived image so container recreation does not
discard package installations.

## Network design

Olympus currently uses plain Flannel without a separate NetworkPolicy
enforcement engine. Existing Kubernetes `NetworkPolicy` resources therefore
must not be treated as the security boundary for Hermes. An ordinary pod could
still reach sensitive internal HTTP services, including Longhorn management.
This is the main reason to prefer a VM over an always-on Hermes StatefulSet.

The guest firewall must be configured and owned outside the Hermes container.
Its intended policy is:

- Deny unsolicited inbound traffic except the required Tailscale path.
- Deny access to LAN, Kubernetes pod, Kubernetes service, Talos API, Longhorn,
  SMB, NFS, and link-local/metadata networks.
- Permit DNS, NTP, HTTPS, GitHub, selected model-provider APIs, and other public
  destinations that are explicitly required.
- Keep the Hermes API/dashboard bound to loopback where practical and publish
  it with Tailscale Serve and ACLs restricted to Jacob.
- Do not expose Hermes directly through Cloudflare Tunnel initially.

A future implementation should test these rules from inside Hermes, including
negative tests against the Kubernetes API, Longhorn backend, node addresses,
NAS ports, and service/pod CIDRs.

## Credentials and approvals

The VM boundary cannot protect an external service from credentials deliberately
given to Hermes. Credentials therefore remain least-privilege capabilities:

- Use a dedicated GitHub App or fine-grained installation credential limited
  to selected repositories.
- Do not grant repository administration or deletion permissions.
- Store provider and integration secrets through SOPS and expose only those
  required by Hermes.
- Restrict chat gateways to Jacob's explicit Telegram, Discord, or other caller
  identifiers.
- Keep destructive-action approvals enabled. Do not make permanent YOLO mode
  the default for the durable VM.

Hermes may be unrestricted within its container while still requiring approval
for actions that affect external systems.

## User interface

Start headless. The official Hermes container includes Chromium/Playwright and
should cover most browser automation without a desktop environment. Add the
Hermes dashboard as a launcher entry after the Tailscale-only route is working.
Headlamp can provide the Kubernetes-side VM health and restart view.

If real desktop control is later required, add a lightweight isolated display
inside the VM—Xvfb plus Openbox or XFCE, Chromium, and noVNC—instead of a full
GNOME installation. Keep the display reachable only over Tailscale. Unattended
computer-use experiments should run in a disposable snapshot or clone rather
than against the durable primary VM.

## Persistence and recovery

- Flux owns KubeVirt/CDI installation and the permanent VM definition.
- SOPS owns Kubernetes-side secrets; plaintext secrets are never committed.
- Longhorn owns the OS and data PVCs.
- The Hermes data disk receives recurring R2 backups.
- Take a Longhorn snapshot before Hermes image or major configuration upgrades.
- Replacing the container or rebuilding the guest must not replace the data
  disk.
- Deleting the VM manifest must not automatically delete retained data PVCs.
- Do not import the deleted Atlas `~/.hermes` directory. Start with clean state.

## Future implementation gates

Before implementation, explicitly verify:

1. Current KubeVirt/CDI and Kubernetes/Talos version compatibility.
2. `/dev/kvm` and any required `vhost` devices on every eligible node.
3. Longhorn free capacity, placement, replica health, backup target health, and
   PVC deletion policies.
4. VM migration/eviction behavior with Longhorn ReadWriteOnce volumes.
5. Rootless Podman support for the pinned official Hermes image and Chromium.
6. Guest firewall rules and Tailscale ACL design before adding credentials.
7. Recovery from a fresh guest while attaching a restored Hermes data volume.

Implementation is complete only after persistence, backup restoration, network
denial, container isolation, gateway access, and browser operation are tested.

## References

- [Hermes Agent security policy](https://github.com/NousResearch/hermes-agent/security)
- [Hermes Agent Docker guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/docker.md)
- [Hermes Agent computer-use guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/computer-use.md)
- [Coder templates](https://coder.com/docs/admin/templates)
- [Coder external workspaces](https://coder.com/docs/admin/templates/managing-templates/external-workspaces)
- [KubeVirt installation](https://kubevirt.io/user-guide/cluster_admin/installation/)
- [KubeVirt storage](https://kubevirt.io/user-guide/storage/disks_and_volumes/)
- [KubeVirt networking](https://kubevirt.io/user-guide/network/interfaces_and_networks/)
