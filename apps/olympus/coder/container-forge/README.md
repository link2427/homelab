---
display_name: Container Forge
description: Build Docker-compatible Linux/amd64 archives for offline transfer
icon: /icon/container.svg
tags: [kubernetes, container, docker, offline]
---

# Container Forge

Container Forge is an Olympus Coder workspace for authoring Dockerfiles and
exporting Docker-loadable Linux/amd64 image archives without Docker-in-Docker or
a host Docker socket.

The interactive agent and a disposable Kaniko builder run in the isolated
`coder-forge` namespace. Projects, export bundles, and registry credentials are
stored on the workspace home volume. Builder cache has a separate disposable
volume. The builder is recycled after every build.

The creation form has sliders for builder CPU, builder memory, persistent
project/export capacity, and disposable cache capacity. Visual storage and host
choices explain the tradeoffs. Four presets cover quick images, the normal
Forge, SSD-backed iteration, and large CUDA images. Host choice always pins both
pods to the same node so their shared ReadWriteOnce volumes remain safe.

Build an image with:

```bash
container-build example:1.0 . -f Dockerfile
```

The resulting directory under `/home/coder/exports` contains the Docker archive,
SHA-256 checksum, JSON manifest, build log, and `docker load` instructions. Open
the **Container Exports** app to download it. Use `container-split` when an
archive must be divided across multiple discs.

Agent buttons use named Zellij sessions, so closing and reopening the browser app
reattaches to the running CLI while the workspace remains started. Stopping a
workspace, updating it, or rescheduling its pod terminates live processes;
persistent files and agent history remain on Longhorn for normal resume.

The builder is the maintained `ghcr.io/osscontainertools/kaniko:v1.28.2-alpine`
fork pinned by image digest. It has no Docker socket, Docker-in-Docker daemon, or
privileged security context. A complete smoke test has verified that its output
passes SHA-256 validation, loads with `docker load`, reports `linux/amd64`, and
runs through a normal Docker Engine.
