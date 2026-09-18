"""Public WSGI server: fixed resources only, no Kubernetes client or credentials."""
import hashlib
from http import HTTPStatus
import json
import os
from pathlib import Path
import time

from collector import timestamp

PREFIX = "/api/olympus/v1"
SNAPSHOT = Path(os.environ.get("SNAPSHOT_DIR", "/snapshot")) / "cluster.json"
ROOT = Path(__file__).parent
DOCUMENTS = {PREFIX + "/schema.json": ("schema.json", "application/schema+json"),
             PREFIX + "/types.ts": ("types.ts", "text/plain; charset=utf-8"),
             PREFIX + "/integration": ("INTEGRATION.md", "text/markdown; charset=utf-8")}


def application(environ, start_response):
    method, path = environ.get("REQUEST_METHOD", "GET"), environ.get("PATH_INFO", "")
    headers = {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
               "Access-Control-Allow-Origin": "*", "X-Content-Type-Options": "nosniff",
               "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
               "Referrer-Policy": "no-referrer"}
    code, body = 200, b""
    if method not in {"GET", "HEAD"}:
        code, body = 405, b'{"error":"read_only"}'
        headers["Allow"] = "GET, HEAD"
    elif path == "/healthz":
        body = b'{"status":"ok"}'
    elif path in {PREFIX + "/cluster", "/readyz"}:
        try:
            snapshot = json.loads(SNAPSHOT.read_bytes())
            stale = time.time() >= timestamp(snapshot["expiresAt"])
            snapshot["stale"] = stale
            if stale:
                snapshot["cluster"]["status"] = "unknown"
            # Readiness requires an initial snapshot, then continues serving stale data.
            body = b'{"status":"ready"}' if path == "/readyz" else json.dumps(snapshot, separators=(",", ":"), allow_nan=False).encode()
            if not stale and path != "/readyz":
                ttl = max(0, min(15, int(timestamp(snapshot["expiresAt"]) - time.time())))
                headers["Cache-Control"] = f"public, max-age={ttl}, must-revalidate"
        except (OSError, ValueError, KeyError):
            code, body = 503, b'{"error":"snapshot_unavailable","retryAfterSeconds":30}'
            headers["Retry-After"] = "30"
    elif path in DOCUMENTS:
        filename, headers["Content-Type"] = DOCUMENTS[path]
        body = (ROOT / filename).read_bytes()
        headers["Cache-Control"] = "public, max-age=300, must-revalidate"
    elif path in {"/api/olympus", "/api/olympus/", PREFIX}:
        body = json.dumps({"name": "Olympus public cluster feed", "schemaVersion": "1.0",
                           "cluster": PREFIX + "/cluster", "schema": PREFIX + "/schema.json",
                           "integration": PREFIX + "/integration", "types": PREFIX + "/types.ts"}).encode()
    else:
        code, body = 404, b'{"error":"not_found"}'
    if code == 200:
        headers["ETag"] = '"' + hashlib.sha256(body).hexdigest() + '"'
        if environ.get("HTTP_IF_NONE_MATCH") == headers["ETag"]:
            code, body = 304, b""
    if code != 304:
        headers["Content-Length"] = str(len(body))
    start_response(f"{code} {HTTPStatus(code).phrase}", list(headers.items()))
    return [b"" if method == "HEAD" else body]
