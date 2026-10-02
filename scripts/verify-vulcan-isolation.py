"""Temporary restricted per-node probes; requires kubectl admin access, no secrets.

Run after gateway/store deployment with submissions still disabled. Creates only
uniquely named test Pods in default/vulcan-jobs, then deletes those exact Pods.
Writes a sanitized JSON report to stdout. Never applies Flux-managed resources.
"""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid


def kubectl(*args, data=None):
    result = subprocess.run(["kubectl", *args], input=data, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


SERVER = """
import socket,threading,time
def serve(kind):
    s=socket.socket(socket.AF_INET,kind); s.bind(('0.0.0.0',18080))
    if kind==socket.SOCK_STREAM:
        s.listen()
        while True:
            c,a=s.accept(); c.close()
    else:
        while True:
            b,a=s.recvfrom(1024); s.sendto(b,a)
for k in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
    threading.Thread(target=serve,args=(k,),daemon=True).start()
time.sleep(1800)
"""
PROBE = """
import concurrent.futures,json,socket,struct,sys
def probe(t):
    try:
        kind=socket.SOCK_DGRAM if t.get('udp') else socket.SOCK_STREAM
        with socket.socket(socket.AF_INET,kind) as s:
            s.settimeout(2); s.connect((t['host'],t['port']))
            if t.get('dns'):
                q=b'\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00'+b''.join(bytes([len(p)])+p.encode() for p in 'kubernetes.default.svc.cluster.local'.split('.'))+b'\\x00\\x00\\x01\\x00\\x01'
                s.sendall(q if t.get('udp') else struct.pack('!H',len(q))+q)
                assert s.recv(4096)
            elif t.get('udp'):
                s.send(b'vulcan-canary'); assert s.recv(1024)==b'vulcan-canary'
        return {**t,'reachable':True}
    except Exception as e:
        return {**t,'reachable':False,'error':type(e).__name__}
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
    print(json.dumps(list(pool.map(probe,json.loads(sys.argv[1])))))
"""


def main():
    config = json.loads((Path(__file__).resolve().parents[1] / "apps/olympus/vulcan/config.json").read_text())
    image = config["images"]["python"]["image"]
    nodes = json.loads(kubectl("get", "nodes", "-o", "json"))["items"]
    assert nodes and all(any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"]["conditions"]) for n in nodes)
    run = "vulcan-canary-" + uuid.uuid4().hex[:8]
    created, pods = [], []
    try:
        for i, node in enumerate(nodes):
            for namespace in ("default", "vulcan-jobs"):
                name = run + "-" + str(i)
                spec = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": namespace,
                    "labels": {"app.kubernetes.io/name": "vulcan-task", "vulcan.olympus/identity": "canary-" + str(i)}},
                    "spec": {"nodeName": node["metadata"]["name"], "automountServiceAccountToken": False,
                        "enableServiceLinks": False, "restartPolicy": "Never", "activeDeadlineSeconds": 1800,
                        "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000,
                            "seccompProfile": {"type": "RuntimeDefault"}},
                        "containers": [{"name": "probe", "image": image, "command": ["python3", "-c", SERVER],
                            "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                            "resources": {"requests": {"cpu": "100m", "memory": "64Mi", "ephemeral-storage": "1Gi"}, "limits": {"cpu": "1", "memory": "128Mi", "ephemeral-storage": "1Gi"}},
                            "readinessProbe": {"tcpSocket": {"port": 18080}, "periodSeconds": 2}}]}}
                kubectl("create", "-f", "-", data=json.dumps(spec))
                created.append((namespace, name))
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            pods = [json.loads(kubectl("-n", ns, "get", "pod", name, "-o", "json")) for ns, name in created]
            if all(any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", [])) for p in pods):
                break
            time.sleep(5)
        else:
            raise RuntimeError("Canary Pods did not become Ready")
        targets = []
        for pod in pods:
            for udp in (False, True):
                targets.append({"name": pod["metadata"]["namespace"] + "/" + pod["spec"]["nodeName"] + ("/udp" if udp else "/tcp"),
                    "host": pod["status"]["podIP"], "port": 18080, "udp": udp, "allowed": False,
                    "control_required": pod["metadata"]["namespace"] == "default"})
        services = json.loads(kubectl("get", "svc", "-A", "-o", "json"))["items"]
        service = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in services}
        for ns, name, port, allowed in [("default", "kubernetes", 443, False), ("vulcan", "vulcan-store", 8333, True),
                ("coder", "coder-postgres", 5432, False), ("authentik", "authentik-postgres", 5432, False),
                ("netbox", "netbox-postgres", 5432, False), ("netbox", "netbox-valkey", 6379, False)]:
            targets.append({"name": ns + "/" + name, "host": service[(ns, name)]["spec"]["clusterIP"], "port": port, "allowed": allowed})
        for udp in (False, True):
            targets.append({"name": "cluster-dns/" + ("udp" if udp else "tcp"), "host": service[("kube-system", "kube-dns")]["spec"]["clusterIP"],
                "port": 53, "udp": udp, "dns": True, "allowed": True, "control_required": True})
        store = json.loads(kubectl("-n", "vulcan", "get", "pods", "-l", "app=vulcan-store", "-o", "json"))["items"][0]["status"]["podIP"]
        for port in (8333, 8888, 9333, 8080):
            targets.append({"name": "store-pod/" + str(port), "host": store, "port": port, "allowed": port == 8333})
        for node in nodes:
            address = next(a["address"] for a in node["status"]["addresses"] if a["type"] == "InternalIP")
            targets.append({"name": "node/" + node["metadata"]["name"], "host": address, "port": 10250, "allowed": False, "control_required": True})
        targets += [{"name": "store-dns-name", "host": "vulcan-store.vulcan.svc.cluster.local", "port": 8333, "allowed": True},
                    {"name": "api-node", "host": "10.0.0.57", "port": 6443, "allowed": False, "control_required": True},
                    {"name": "lan-router", "host": "10.0.0.1", "port": 80, "allowed": False},
                    {"name": "metadata", "host": "169.254.169.254", "port": 80, "allowed": False},
                    {"name": "internet-tcp", "host": "1.1.1.1", "port": 443, "allowed": False, "control_required": True},
                    {"name": "internet-dns", "host": "1.1.1.1", "port": 53, "udp": True, "dns": True, "allowed": False, "control_required": True}]
        def check(pod):
            # A pod may always connect to itself; test every other node/identity.
            selected = [t for t in targets if t["host"] != pod["status"]["podIP"]]
            ns, name = pod["metadata"]["namespace"], pod["metadata"]["name"]
            rows = json.loads(kubectl("-n", ns, "exec", name, "--", "python3", "-c", PROBE, json.dumps(selected)))
            failures = [r for r in rows if (ns == "vulcan-jobs" and r["reachable"] != r["allowed"]) or (ns == "default" and r.get("control_required") and not r["reachable"])]
            return {"namespace": ns, "node": pod["spec"]["nodeName"], "checks": rows, "failures": failures}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(check, pods))
        report = {"run": run, "scope": "live Olympus per-node network checks", "results": results,
                  "passed": all(not r["failures"] for r in results),
                  "note": "Unreachable control targets alone do not prove policy denial; explicit control_required checks prove live allowed/denied paths."}
        print(json.dumps(report, indent=2))
        return 0 if report["passed"] else 1
    finally:
        for ns, name in created:
            kubectl("-n", ns, "delete", "pod", name, "--wait=false", "--ignore-not-found")


if __name__ == "__main__":
    sys.exit(main())
