FROM golang:1.26.8-bookworm AS edge
WORKDIR /src
COPY edge/go.mod edge/go.sum ./
RUN go mod download
COPY edge/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /vulcan-edge .

FROM ghcr.io/astral-sh/uv:0.11.5 AS uv
FROM python:3.12.13-slim-bookworm
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-cache
COPY --from=edge /vulcan-edge /usr/local/bin/vulcan-edge
COPY app.py worker.py start.py ./
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 1000:1000
ENTRYPOINT ["python", "start.py"]
