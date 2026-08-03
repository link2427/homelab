# Spegel image cache

Spegel 0.7.4 runs as a registry-mirror DaemonSet on every Talos node. Each node
advertises the OCI layers in its local containerd content store so another node
can fetch those layers over the cluster network before falling back to the
upstream registry. Mutable `latest` tags bypass Spegel.

The `coder-image-cache` DaemonSet keeps the standard Coder base and universal
workspace images present on all nodes. `coder-gpu-image-cache` does the same for
the PyTorch CUDA image on the two GPU nodes. These images use `IfNotPresent`, so
the pre-pullers do not repeatedly contact the upstream registry after a node has
the image.

Talos normally discards compressed content after unpacking an image. Apply the
included machine configuration patch to every node before deploying Spegel.
Talos 1.12 already ships the empty
`/etc/cri/conf.d/20-customization.part` file, so the patch overwrites that
existing file; creating a new file elsewhere under `/etc` is rejected during
boot.

```powershell
$talosConfig = "C:\Users\Jacob\talos-node-setup\longhorn-setup-20260802\talosconfig.before"
$patch = "D:\repos\homelab\infrastructure\olympus\spegel\talos-machine.patch.yaml"

talosctl --talosconfig $talosConfig --endpoints 10.0.0.57 --nodes 10.0.0.25 patch machineconfig --patch-file $patch --mode reboot
talosctl --talosconfig $talosConfig --endpoints 10.0.0.57 --nodes 10.0.0.171 patch machineconfig --patch-file $patch --mode reboot
talosctl --talosconfig $talosConfig --endpoints 10.0.0.57 --nodes 10.0.0.57 patch machineconfig --patch-file $patch --mode reboot
```

The file change requires a reboot. Drain, patch, verify, and uncordon each node
individually, processing workers before the sole control-plane node. The
`spegel` namespace is privileged because
the chart mounts the Talos containerd socket, content store, registry
configuration directory, and host port required to provide the local mirror.
Prometheus discovers Spegel metrics through the pod scrape annotations.

Deploy the Helm release and verify all Spegel pods first. Then add
`image-prepuller.yaml` to this directory's `resources` list so the large Coder
and PyTorch images are populated only after the peer mirror is available. The
pre-puller pods deliberately stay running to keep those images referenced and
reduce kubelet garbage-collection pressure.

Spegel is an opportunistic pull-through peer cache, not an image registry or
backup. A cache miss falls back to the upstream registry, and mutable `latest`
tags are excluded from peer resolution.
