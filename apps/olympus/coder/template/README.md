# Olympus Coder Workspaces

One source publishes four focused Kubernetes workspace templates. The `profile`
and `image` Terraform variables are fixed per template version; developers only
see the relevant resource, storage, and GPU parameters.

| Template | Profile | Purpose | Default storage |
| --- | --- | --- | --- |
| `olympus-linux` | `linux` | Lightweight everyday Linux development | Fast SSD, 2 replicas |
| `olympus-agent` | `agent` | Autonomous agents with Codex, Claude Code, OpenCode, and Reasonix | Fast SSD, 2 replicas |
| `olympus-gpu` | `gpu` | CUDA 12.6 PyTorch development with JupyterLab and persistent model/kernel caches | Fast SSD, 2 replicas |
| `olympus-build` | `build` | Large builds and caches pinned to the 7810 | Bulk HDD, 1 replica + backup |

All persistent home volumes receive daily Longhorn backups to Atlas. CPU,
memory, home size, and storage tier are selectable. GPU-capable profiles can
select the exact physical card:

- Quadro M4000, 8 GiB, on `precision-5810-01`
- Quadro P2000, 5 GiB, on `precision-7810-01`
- No GPU, with normal Kubernetes placement

GPU selection adds both the `nvidia.com/gpu: 1` limit and a hostname node
selector, so Kubernetes cannot silently assign the other card.

`olympus-agent` exposes the official Coder integrations for Codex, Claude Code,
and OpenCode. Reasonix 1.19.1 is installed into the persistent home directory,
so all four tools survive workspace rebuilds and can keep their user-level
configuration with the workspace.

`olympus-gpu` uses the official PyTorch 2.13.0 CUDA 12.6 runtime image. CUDA
12.6 is intentional: unlike CUDA 13, it retains binary support for both the
Maxwell M4000 and Pascal P2000. Hugging Face, Torch, extension, Matplotlib, and
Jupyter caches live on the persistent home volume.

## Publishing

```sh
coder templates push olympus-linux -d . --var profile=linux --var image=codercom/example-base:ubuntu -y
coder templates push olympus-agent -d . --var profile=agent --var image=codercom/example-universal:ubuntu -y
coder templates push olympus-gpu -d . --var profile=gpu --var image=pytorch/pytorch:2.13.0-cuda12.6-cudnn9-runtime -y
coder templates push olympus-build -d . --var profile=build --var image=codercom/example-universal:ubuntu -y
```

Workspace Kubernetes permissions remain confined to the `coder` namespace.
