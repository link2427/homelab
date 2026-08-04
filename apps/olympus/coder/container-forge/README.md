---
display_name: Container Forge
description: Build Docker-compatible Linux/amd64 archives for offline transfer
icon: /icon/docker.svg
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
workspace terminates its processes; persistent files remain on Longhorn.
