# Olympus Linux Workspace

Coder Kubernetes workspace template for autonomous development agents and interactive development.

- Workspace compute is ephemeral and disappears when the workspace is stopped.
- `/home/coder` is persistent on the `longhorn-fast` NVMe/SSD tier.
- Home volumes receive daily Longhorn backups to Atlas.
- CPU, memory, disk size, and optional NVIDIA GPU allocation are selectable.
- Kubernetes permissions are confined to the `coder` namespace.

After creating the first Coder administrator, push this directory as the `olympus-linux` template with the Coder CLI.
