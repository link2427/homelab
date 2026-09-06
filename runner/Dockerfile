# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 AS node
FROM ghcr.io/actions/actions-runner:2.337.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git git-lfs jq unzip zip zstd rsync \
    python3 python3-venv python3-pip python-is-python3 gh pkg-config libssl-dev cmake ninja-build \
    openssh-client postgresql-client ffmpeg libicu74 liblttng-ust1t64 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && mkdir -p /opt/hostedtoolcache /opt/microsoft/powershell/7 \
    && chown runner:runner /opt/hostedtoolcache \
    && curl -fsSL https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/powershell-7.6.5-linux-x64.tar.gz -o /tmp/pwsh.tgz \
    && echo 'b34ab3b19acac1d3d4d0d3cfdb02acf62f457b0b6a962ff008132033f7566844  /tmp/pwsh.tgz' | sha256sum -c - \
    && tar -xzf /tmp/pwsh.tgz -C /opt/microsoft/powershell/7 \
    && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh \
    && rm /tmp/pwsh.tgz
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose \
    && echo 'db1889184726840f75c4f9c001048430d4f25b3be3cb084d3ddd762bc0aed576  /usr/local/lib/docker/cli-plugins/docker-compose' | sha256sum -c - \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
    && mkdir -p /opt/hostedtoolcache/node/22.23.2 \
    && ln -s /usr/local /opt/hostedtoolcache/node/22.23.2/x64 \
    && touch /opt/hostedtoolcache/node/22.23.2/x64.complete \
    && chown -R runner:runner /opt/hostedtoolcache/node
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
USER runner
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.98.1 --component clippy,rustfmt \
    && rm /tmp/rustup.sh
ENV PATH="/home/runner/.cargo/bin:${PATH}"
LABEL org.opencontainers.image.source="https://github.com/link2427/homelab"
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1-mesa-dev libglu1-mesa-dev libx11-dev libxrandr-dev libxi-dev \
    libxcursor-dev libxinerama-dev libwayland-dev libxkbcommon-dev \
    libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf \
    && rm -rf /var/lib/apt/lists/*
USER runner
