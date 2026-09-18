"""Read cluster metadata; write only the explicit public projection to disk."""
import concurrent.futures
import datetime as dt
import json
import logging
import os
from pathlib import Path
import re
import ssl
import time
import urllib.parse
import urllib.request
from decimal import Decimal

INTERVAL = 30
MAX_AGE = 120
SOURCES = {
    "nodes": "/api/v1/nodes",
    "pods": "/api/v1/pods",
    "deployments": "/apis/apps/v1/deployments",
    "statefulsets": "/apis/apps/v1/statefulsets",
    "daemonsets": "/apis/apps/v1/daemonsets",
    "cronjobs": "/apis/batch/v1/cronjobs",
    "metrics": "/apis/metrics.k8s.io/v1beta1/nodes",
    "storage": "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes",
    "gitops": "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations",
}
CORE = {"nodes", "pods", "deployments", "statefulsets", "daemonsets", "cronjobs"}
ARCHIVED = {"atlas-migration", "nfs-provisioner"}
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
GROUPS = {
    "actions-runners": "Build infrastructure", "arc-system": "Build infrastructure",
    "authentik": "Identity", "coder": "Development", "coder-forge": "Development",
    "cosmotrak": "Public applications", "cosmotrak-notifications": "Cosmotrak services",
    "flux-system": "GitOps", "kube-system": "Kubernetes", "longhorn-system": "Storage",
    "media-automation": "Media", "nas": "Storage", "monitoring": "Observability",
    "personal-website": "Public applications", "shaderweave": "Public applications",
    "spegel": "Build infrastructure", "tailscale": "Networking", "vpn-egress": "Networking",
    "nvidia-device-plugin": "GPU infrastructure", "plex": "Media",
    "satellite-data-dev": "Satellite data", "satellite-data-prod": "Satellite data",
    "telchar-forge": "Telchar Forge", "telchar-construct": "Public applications",
    "olympus-status": "Observability",
}
LINKS = {
    "cosmotrak/cosmotrak": "https://cosmotrak.com",
    "personal-website/personal-website": "https://jacob-neel.com",
    "shaderweave/shaderweave-web": "https://shaderweave.com",
}


def iso(timestamp):
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def timestamp(value):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return 0


def quantity(value):
    """Kubernetes quantities, including nano CPU, binary memory and exponents."""
    match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)([a-zA-Z]*)", str(value))
    if not match:
        raise ValueError("invalid quantity")
    number, unit = match.groups()
    factors = {"": 1, "n": 1e-9, "u": 1e-6, "m": 1e-3,
               **{u: 1000 ** i for i, u in enumerate("kMGTPE", 1)},
               **{u + "i": 1024 ** i for i, u in enumerate("KMGTPE", 1)}}
    return float(Decimal(number) * Decimal(str(factors[unit])))


def text(value):
    # No arbitrary labels, error messages, annotations or other nested objects.
    return str(value)[:160] if value is not None else None


def condition(obj, name):
    return next((c.get("status") for c in obj.get("status", {}).get("conditions", []) if c.get("type") == name), "Unknown")


def visible(obj):
    meta = obj.get("metadata", {})
    return meta.get("namespace") not in ARCHIVED and meta.get("annotations", {}).get("status.olympus.dev/visibility") != "private"


def workload(obj):
    meta, spec, status = obj["metadata"], obj.get("spec", {}), obj.get("status", {})
    namespace, name = meta["namespace"], meta["name"]
    kind = obj["kind"]
    desired = status.get("desiredNumberScheduled", 0) if kind == "DaemonSet" else spec.get("replicas", 1)
    ready = status.get("numberReady", 0) if kind == "DaemonSet" else status.get("readyReplicas", 0)
    available = status.get("numberAvailable", 0) if kind == "DaemonSet" else status.get("availableReplicas", ready)
    updated = status.get("updatedNumberScheduled", 0) if kind == "DaemonSet" else status.get("updatedReplicas", 0)
    observed = status.get("observedGeneration", 0) >= meta.get("generation", 1)
    health = "paused" if desired == 0 else "unknown" if not observed else "healthy" if min(ready, available, updated) >= desired else "degraded"
    grouped = "workspaces" if UUID.search(name) else "tailnet-proxies" if namespace == "tailscale" and name.startswith("ts-") else "storage-engines" if name.startswith("engine-image-") else None
    public_name = {"workspaces": "Development workspaces", "tailnet-proxies": "Private service connections", "storage-engines": "Storage engines"}.get(grouped, name.replace("-", " ").title())
    return {"id": f"{namespace}/{grouped or kind.lower() + '/' + name}", "name": public_name,
            "namespace": namespace, "category": GROUPS.get(namespace, "Services"),
            "kind": "Group" if grouped else kind, "status": health,
            "desiredReplicas": desired, "readyReplicas": ready, "members": 1,
            "publicUrl": LINKS.get(f"{namespace}/{name}")}


def project(raw, now):
    """Build the whole contract from fresh reads. Never serialize a source object."""
    missing = sorted(name for name in [*SOURCES, "hardware"] if raw.get(name) is None)
    metrics = {m["metadata"]["name"]: m for m in (raw.get("metrics") or [])}
    hardware = {}
    for entry in raw.get("hardware") or []:
        # Match internally on IP. Publish only vendor/model, never the identifier.
        metric = entry.get("metric", {})
        hardware[metric.get("instance", "").rsplit(":", 1)[0]] = metric
    nodes = []
    for obj in raw["nodes"]:
        meta, status = obj["metadata"], obj.get("status", {})
        capacity, allocatable, info = status.get("capacity", {}), status.get("allocatable", {}), status.get("nodeInfo", {})
        m = metrics.get(meta["name"], {})
        measured = timestamp(m.get("timestamp"))
        usage = m.get("usage", {}) if 0 <= now - measured <= MAX_AGE else {}
        model = next((hardware[a["address"]] for a in status.get("addresses", []) if a["address"] in hardware), {})
        cpu, memory = quantity(capacity.get("cpu", 0)), int(quantity(capacity.get("memory", 0)))
        used_cpu = round(quantity(usage["cpu"]), 4) if "cpu" in usage else None
        used_memory = int(quantity(usage["memory"])) if "memory" in usage else None
        nodes.append({"id": meta["name"], "name": meta["name"],
                      "role": "control-plane" if "node-role.kubernetes.io/control-plane" in meta.get("labels", {}) else "worker",
                      "status": "healthy" if condition(obj, "Ready") == "True" else "degraded" if condition(obj, "Ready") == "False" else "unknown",
                      "architecture": text(info.get("architecture")), "operatingSystem": text(info.get("osImage")),
                      "kubernetesVersion": text(info.get("kubeletVersion")), "model": text(model.get("product_name")),
                      "manufacturer": text(model.get("system_vendor")),
                      "cpuCores": cpu, "memoryBytes": memory,
                      "allocatableCpuCores": quantity(allocatable.get("cpu", 0)),
                      "allocatableMemoryBytes": int(quantity(allocatable.get("memory", 0))),
                      "gpuSchedulingUnits": int(quantity(capacity.get("nvidia.com/gpu", 0))),
                      "usage": {"measuredAt": iso(measured) if usage else None,
                                "cpuCores": used_cpu, "memoryBytes": used_memory,
                                "cpuPercent": round(100 * used_cpu / cpu, 2) if used_cpu is not None and cpu else None,
                                "memoryPercent": round(100 * used_memory / memory, 2) if used_memory is not None and memory else None}})
    services = {}
    for obj in raw["deployments"] + raw["statefulsets"] + raw["daemonsets"]:
        if not visible(obj):
            continue
        service = workload(obj)
        key = service["id"]
        if key in services:
            previous = services[key]
            for field in ["desiredReplicas", "readyReplicas", "members"]:
                previous[field] += service[field]
            states = {previous["status"], service["status"]}
            previous["status"] = "degraded" if "degraded" in states else "unknown" if "unknown" in states else "healthy" if "healthy" in states else "paused"
        else:
            services[key] = service
    jobs = [{"id": f"{o['metadata']['namespace']}/{o['metadata']['name']}",
             "name": o["metadata"]["name"].replace("-", " ").title(),
             "namespace": o["metadata"]["namespace"],
             "suspended": o["spec"].get("suspend", False),
             "activeJobs": len(o.get("status", {}).get("active", [])),
             "lastSucceededAt": o.get("status", {}).get("lastSuccessfulTime")}
            for o in raw["cronjobs"] if visible(o)]
    active_pods = [p for p in raw["pods"] if p.get("status", {}).get("phase") not in {"Succeeded", "Failed"} and not p.get("metadata", {}).get("deletionTimestamp")]
    storage = None
    if raw.get("storage") is not None:
        disks = [d for n in raw["storage"] for d in n.get("status", {}).get("diskStatus", {}).values()]
        storage = {"provider": "Longhorn", "disks": len(disks),
                   "readyDisks": sum(condition({"status": d}, "Ready") == "True" for d in disks),
                   "physicalCapacityBytes": sum(d.get("storageMaximum", 0) for d in disks),
                   "physicalAvailableBytes": sum(d.get("storageAvailable", 0) for d in disks)}
    gitops = None if raw.get("gitops") is None else {"total": len(raw["gitops"]), "ready": sum(condition(o, "Ready") == "True" for o in raw["gitops"])}
    states = [n["status"] for n in nodes] + [s["status"] for s in services.values()]
    health = "degraded" if "degraded" in states or (gitops and gitops["ready"] < gitops["total"]) or (storage and storage["readyDisks"] < storage["disks"]) else "unknown" if "unknown" in states or not nodes else "healthy"
    measured_nodes = [n for n in nodes if n["usage"]["cpuCores"] is not None and n["usage"]["memoryBytes"] is not None]
    all_measured = bool(nodes) and len(measured_nodes) == len(nodes)
    return {"schemaVersion": "1.0", "cluster": {"id": "olympus", "name": "Olympus", "status": health},
            "generatedAt": iso(now), "expiresAt": iso(now + MAX_AGE), "refreshIntervalSeconds": INTERVAL,
            "stale": False, "partial": bool(missing) or not all_measured, "unavailableSources": missing,
            "summary": {"nodes": len(nodes), "readyNodes": sum(n["status"] == "healthy" for n in nodes),
                        "cpuCores": sum(n["cpuCores"] for n in nodes), "memoryBytes": sum(n["memoryBytes"] for n in nodes),
                        "gpuSchedulingUnits": sum(n["gpuSchedulingUnits"] for n in nodes),
                        "activePods": len(active_pods), "readyPods": sum(condition(p, "Ready") == "True" for p in active_pods),
                        "services": len(services), "healthyServices": sum(s["status"] == "healthy" for s in services.values()),
                        "pausedServices": sum(s["status"] == "paused" for s in services.values()),
                        "usage": {"measuredNodes": len(measured_nodes),
                                  "cpuCores": round(sum(n["usage"]["cpuCores"] for n in measured_nodes), 4) if all_measured else None,
                                  "memoryBytes": sum(n["usage"]["memoryBytes"] for n in measured_nodes) if all_measured else None}},
            "nodes": sorted(nodes, key=lambda n: n["id"]),
            "services": sorted(services.values(), key=lambda s: (s["category"], s["id"])),
            "scheduledJobs": sorted(jobs, key=lambda j: j["id"]), "storage": storage, "gitops": gitops}


class Reader:
    def __init__(self):
        self.credentials = Path(os.environ.get("CREDENTIALS_DIR", "/var/run/collector"))
        self.context = ssl.create_default_context(cafile=str(self.credentials / "ca.crt"))
        self.api = "https://kubernetes.default.svc"
        # Fixed origin and query. Public request data can never reach this process.
        self.prometheus = "http://prometheus.monitoring.svc.cluster.local:9090"

    def get(self, source):
        if source == "hardware":
            url = self.prometheus + "/api/v1/query?" + urllib.parse.urlencode({"query": 'node_dmi_info{job="node-exporter"}'})
            with urllib.request.urlopen(url, timeout=8) as response:
                data = json.load(response)
            if data.get("status") != "success":
                raise ValueError("hardware unavailable")
            return data["data"]["result"]
        items, continuation = [], ""
        for _ in range(100):
            # Token is reread for every page so projected-token rotation is safe.
            headers = {"Authorization": "Bearer " + (self.credentials / "token").read_text().strip()}
            query = urllib.parse.urlencode({"limit": 500, "continue": continuation})
            request = urllib.request.Request(self.api + SOURCES[source] + "?" + query, headers=headers)
            with urllib.request.urlopen(request, context=self.context, timeout=8) as response:
                data = json.load(response)
            items.extend(data["items"])
            continuation = data.get("metadata", {}).get("continue", "")
            if not continuation:
                return items
        raise ValueError("pagination limit")


def collect(reader):
    raw = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        futures = {pool.submit(reader.get, name): name for name in [*SOURCES, "hardware"]}
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                raw[name] = future.result()
            except Exception:
                # Never log upstream errors, bodies, URLs, object names or credentials.
                logging.warning("source unavailable: %s", name)
                raw[name] = None
    if any(raw.get(key) is None for key in CORE):
        raise ValueError("core discovery incomplete")
    return project(raw, time.time())


def write_snapshot(snapshot, directory):
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "snapshot.tmp"
    temporary.write_text(json.dumps(snapshot, separators=(",", ":"), allow_nan=False), encoding="utf-8")
    temporary.replace(directory / "cluster.json")


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    reader = Reader()
    directory = Path(os.environ.get("SNAPSHOT_DIR", "/snapshot"))
    while True:
        start = time.monotonic()
        try:
            snapshot = collect(reader)
            write_snapshot(snapshot, directory)
            logging.info("snapshot published: %s nodes, %s services", snapshot["summary"]["nodes"], snapshot["summary"]["services"])
        except Exception:
            logging.warning("snapshot not updated; retaining last successful observation")
        # Heartbeat is separate from data freshness: API outages must not restart us.
        (directory / "heartbeat").touch()
        time.sleep(max(1, INTERVAL - (time.monotonic() - start)))


if __name__ == "__main__":
    main()
