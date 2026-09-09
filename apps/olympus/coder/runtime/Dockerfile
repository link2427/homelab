FROM codercom/example-universal:ubuntu@sha256:19dfa110f52bc3297891d6a3acaf9d7bfe60604264c2a959d2007063957fc7c8
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 curl ca-certificates git build-essential jq unzip zstd libatomic1 && rm -rf /var/lib/apt/lists/*
COPY runtime/install-image.py /opt/olympus/runtime/install-image.py
COPY runtime/tools.json /opt/olympus/runtime/tools.json
COPY runtime/bin /opt/olympus/runtime/bin
RUN python3 /opt/olympus/runtime/install-image.py
COPY runtime /opt/olympus/runtime
COPY skills/olympus-workspace /opt/olympus/skill
ENV PATH="/opt/olympus/bin:/usr/local/bin:/usr/bin:/bin" \
    UV_PYTHON="/opt/olympus/python/bin/python3" \
    UV_PYTHON_DOWNLOADS="never" \
    DISABLE_AUTOUPDATER="1" \
    OPENCODE_DISABLE_AUTOUPDATE="true"
ARG TOOL_REFRESH=manual
RUN printf '%s\n' "$TOOL_REFRESH" > /opt/olympus/release-generation
# uv requires writable cache locks even in offline mode. Each release owns its cache.
# Set permissions in the install layer, avoiding a full overlay copy of every package.
RUN (HOME=/tmp/olympus-build OLYMPUS_TOOL_ROOT=/opt/olympus/tools OLYMPUS_STATE=/tmp/olympus-build-state \
    python3 /opt/olympus/runtime/olympus-runtime.py update --baseline || \
    { tail -n 60 /tmp/olympus-build-state/logs/install-*.log; exit 1; }) && \
    find /opt/olympus/tools -type d -name uv-cache -exec chown -R 1000:1000 {} + && \
    chmod -R a+rX /opt/olympus/tools && \
    rm -rf /tmp/olympus-build /tmp/olympus-build-state /root/.npm /root/.cache
USER 1000:1000
ENV HOME=/home/coder
WORKDIR /home/coder
CMD ["sleep", "infinity"]
