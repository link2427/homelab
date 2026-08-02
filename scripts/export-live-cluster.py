#!/usr/bin/env python3
"""Export selected live Olympus resources into normalized GitOps manifests.

The resource allow-list intentionally excludes generated Pods, ReplicaSets,
Endpoints, Tailscale proxy objects, Helm storage Secrets, completed Jobs, and
Talos-managed control-plane resources.
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]
RECIPIENT = "age1489u3rqf9c0e4tkah0h50n2ktnkjszlezrvpvkhmvz5y80n7r3fs4dhfcp"
KUBECTL = "kubectl"
SOPS = "sops"

NAMESPACED_KINDS = (
    "deployment,statefulset,daemonset,service,configmap,serviceaccount,"
    "role,rolebinding,persistentvolumeclaim,cronjob"
)


class NoAliasDumper(yaml.SafeDumper):
    def ignore_aliases(self, data):  # noqa: ANN001
        return True


def kubectl_json(*args: str) -> dict:
    result = subprocess.run(
        [KUBECTL, *args, "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return json.loads(result.stdout)


def get_resource(kind: str, name: str, namespace: str | None = None) -> dict:
    args = ["get", kind, name]
    if namespace:
        args.extend(["-n", namespace])
    return kubectl_json(*args)


def namespaced_resources(namespace: str) -> list[dict]:
    result = kubectl_json("get", NAMESPACED_KINDS, "-n", namespace)
    objects = []
    for obj in result.get("items", []):
        name = obj["metadata"]["name"]
        kind = obj["kind"]
        if kind == "ConfigMap" and name == "kube-root-ca.crt":
            continue
        if kind == "ServiceAccount" and name == "default":
            continue
        if kind == "RoleBinding" and name == "aedile-bounded-operator":
            continue
        if kind == "ConfigMap" and name.startswith("forge-mobile-web-dist-part-"):
            continue
        objects.append(obj)
    return objects


def normalize(obj: dict) -> dict:
    obj = copy.deepcopy(obj)
    obj.pop("status", None)
    metadata = obj.setdefault("metadata", {})
    for field in (
        "creationTimestamp",
        "deletionGracePeriodSeconds",
        "deletionTimestamp",
        "generation",
        "managedFields",
        "ownerReferences",
        "resourceVersion",
        "selfLink",
        "uid",
    ):
        metadata.pop(field, None)
    metadata.pop("finalizers", None)

    annotations = metadata.get("annotations", {})
    for key in (
        "deployment.kubernetes.io/revision",
        "kubectl.kubernetes.io/last-applied-configuration",
    ):
        annotations.pop(key, None)
    if annotations:
        metadata["annotations"] = annotations
    else:
        metadata.pop("annotations", None)

    kind = obj.get("kind")
    if kind == "Namespace":
        obj.pop("spec", None)
        metadata.setdefault("annotations", {})[
            "kustomize.toolkit.fluxcd.io/prune"
        ] = "disabled"

    if kind == "PersistentVolumeClaim":
        obj.get("spec", {}).pop("volumeName", None)
        metadata.setdefault("annotations", {})[
            "kustomize.toolkit.fluxcd.io/prune"
        ] = "disabled"

    if kind == "Service":
        spec = obj.get("spec", {})
        if spec.get("clusterIP") != "None":
            spec.pop("clusterIP", None)
            spec.pop("clusterIPs", None)
        spec.pop("healthCheckNodePort", None)
        spec.pop("ipFamilies", None)
        spec.pop("ipFamilyPolicy", None)
        spec.pop("internalTrafficPolicy", None)
        if spec.get("type") == "LoadBalancer":
            spec.pop("allocateLoadBalancerNodePorts", None)
            spec.pop("externalTrafficPolicy", None)
            for port in spec.get("ports", []):
                port.pop("nodePort", None)

    if kind in {"Deployment", "StatefulSet", "DaemonSet"}:
        pod_spec = obj.get("spec", {}).get("template", {}).get("spec", {})
        for container in [
            *pod_spec.get("initContainers", []),
            *pod_spec.get("containers", []),
        ]:
            # Server-side apply rejects duplicate associative-list keys. Preserve
            # Kubernetes' effective behavior by keeping the last env occurrence.
            env = container.get("env", [])
            if env:
                seen = set()
                deduplicated = []
                for entry in reversed(env):
                    name = entry.get("name")
                    if name not in seen:
                        seen.add(name)
                        deduplicated.append(entry)
                container["env"] = list(reversed(deduplicated))
        pod_annotations = (
            obj.get("spec", {})
            .get("template", {})
            .get("metadata", {})
            .get("annotations", {})
        )
        pod_annotations.pop("kubectl.kubernetes.io/restartedAt", None)
        if not pod_annotations:
            obj.get("spec", {}).get("template", {}).get("metadata", {}).pop(
                "annotations", None
            )

    return obj


def write_yaml_documents(path: Path, objects: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    normalized = [normalize(obj) for obj in objects]
    text = yaml.dump_all(
        normalized,
        Dumper=NoAliasDumper,
        default_flow_style=False,
        sort_keys=False,
        explicit_start=True,
    )
    path.write_text(text, encoding="utf-8", newline="\n")


def write_kustomization(path: Path, resources: list[str]) -> None:
    obj = {
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": resources,
    }
    path.write_text(
        yaml.safe_dump(obj, sort_keys=False), encoding="utf-8", newline="\n"
    )


def encrypted_secret_from_live(
    namespace: str, name: str, output: Path, *, rename: str | None = None
) -> None:
    live = get_resource("secret", name, namespace)
    secret = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": rename or name, "namespace": namespace},
        "type": live.get("type", "Opaque"),
        "data": live.get("data", {}),
    }
    encrypt_secret(secret, output)


def encrypt_secret(secret: dict, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch_dir = ROOT / ".flux-local"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".secret.yaml",
            dir=scratch_dir,
            delete=False,
        ) as handle:
            temp_name = handle.name
            yaml.safe_dump(secret, handle, sort_keys=False)
        subprocess.run(
            [
                SOPS,
                "--encrypt",
                "--age",
                RECIPIENT,
                "--encrypted-regex",
                "^(data|stringData)$",
                "--input-type",
                "yaml",
                "--output-type",
                "yaml",
                "--output",
                str(output),
                temp_name,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)


def transform_sensitive_config(app_objects: dict[str, list[dict]]) -> None:
    # Move Grafana's literal administrator password to an encrypted Secret.
    for obj in app_objects["monitoring"]:
        if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "grafana":
            for container in obj["spec"]["template"]["spec"].get("containers", []):
                for env in container.get("env", []):
                    if env.get("name") == "GF_SECURITY_ADMIN_PASSWORD" and "value" in env:
                        value = env.pop("value")
                        env["valueFrom"] = {
                            "secretKeyRef": {
                                "name": "grafana-admin",
                                "key": "admin-password",
                            }
                        }
                        encrypt_secret(
                            {
                                "apiVersion": "v1",
                                "kind": "Secret",
                                "metadata": {
                                    "name": "grafana-admin",
                                    "namespace": "monitoring",
                                },
                                "type": "Opaque",
                                "stringData": {"admin-password": value},
                            },
                            ROOT
                            / "apps/olympus/monitoring/grafana-admin.secret.yaml",
                        )

    # Move Pi-hole's API password out of its plaintext ConfigMap.
    for obj in app_objects["pihole"]:
        if obj["kind"] == "ConfigMap" and obj["metadata"]["name"] == "pihole-env":
            value = obj.get("data", {}).pop("FTLCONF_webserver_api_password", None)
            if value is not None:
                encrypt_secret(
                    {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "metadata": {
                            "name": "pihole-api-password",
                            "namespace": "pihole",
                        },
                        "type": "Opaque",
                        "stringData": {
                            "FTLCONF_webserver_api_password": value,
                        },
                    },
                    ROOT / "apps/olympus/pihole/pihole-api-password.secret.yaml",
                )
    for obj in app_objects["pihole"]:
        if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "pihole":
            for container in obj["spec"]["template"]["spec"].get("containers", []):
                env = container.setdefault("env", [])
                if not any(e.get("name") == "FTLCONF_webserver_api_password" for e in env):
                    env.append(
                        {
                            "name": "FTLCONF_webserver_api_password",
                            "valueFrom": {
                                "secretKeyRef": {
                                    "name": "pihole-api-password",
                                    "key": "FTLCONF_webserver_api_password",
                                }
                            },
                        }
                    )


def export_namespaces() -> None:
    names = [
        "homepage",
        "nfs-provisioner",
        "tailscale",
        "portainer",
        "pihole",
        "n8n",
        "uptime-kuma",
        "monitoring",
        "telchar-forge",
        "telchar-construct",
        "nvidia-device-plugin",
    ]
    output = ROOT / "infrastructure/olympus/namespaces/resources.yaml"
    write_yaml_documents(output, [get_resource("namespace", name) for name in names])
    write_kustomization(output.parent / "kustomization.yaml", ["resources.yaml"])


def export_infrastructure() -> None:
    # NFS provisioners and storage classes.
    nfs = namespaced_resources("nfs-provisioner")
    for kind, name in [
        ("clusterrole", "nfs-subdir-external-provisioner-runner"),
        ("clusterrolebinding", "run-nfs-subdir-external-provisioner"),
        ("storageclass", "nfs-data1"),
        ("storageclass", "nfs-data2"),
    ]:
        nfs.append(get_resource(kind, name))
    nfs_dir = ROOT / "infrastructure/olympus/nfs-provisioner"
    write_yaml_documents(nfs_dir / "resources.yaml", nfs)
    write_kustomization(nfs_dir / "kustomization.yaml", ["resources.yaml"])

    # Metrics Server only; Talos owns the rest of kube-system.
    metrics = [
        get_resource("deployment", "metrics-server", "kube-system"),
        get_resource("service", "metrics-server", "kube-system"),
        get_resource("serviceaccount", "metrics-server", "kube-system"),
        get_resource("rolebinding", "metrics-server-auth-reader", "kube-system"),
        get_resource("clusterrole", "system:aggregated-metrics-reader"),
        get_resource("clusterrole", "system:metrics-server"),
        get_resource("clusterrolebinding", "metrics-server:system:auth-delegator"),
        get_resource("clusterrolebinding", "system:metrics-server"),
        get_resource("apiservice", "v1beta1.metrics.k8s.io"),
    ]
    metrics_dir = ROOT / "infrastructure/olympus/metrics-server"
    write_yaml_documents(metrics_dir / "resources.yaml", metrics)
    write_kustomization(metrics_dir / "kustomization.yaml", ["resources.yaml"])

    # Tailscale operator; generated proxy workloads are intentionally excluded.
    tailscale = [
        get_resource("deployment", "operator", "tailscale"),
        get_resource("serviceaccount", "operator", "tailscale"),
        get_resource("serviceaccount", "proxies", "tailscale"),
        get_resource("role", "operator", "tailscale"),
        get_resource("role", "proxies", "tailscale"),
        get_resource("rolebinding", "operator", "tailscale"),
        get_resource("rolebinding", "proxies", "tailscale"),
        get_resource("clusterrole", "tailscale-operator"),
        get_resource("clusterrolebinding", "tailscale-operator"),
    ]
    for crd in (
        "connectors.tailscale.com",
        "dnsconfigs.tailscale.com",
        "proxyclasses.tailscale.com",
        "proxygrouppolicies.tailscale.com",
        "proxygroups.tailscale.com",
        "recorders.tailscale.com",
        "tailnets.tailscale.com",
    ):
        tailscale.append(get_resource("customresourcedefinition", crd))
    ts_dir = ROOT / "infrastructure/olympus/tailscale-operator"
    write_yaml_documents(ts_dir / "resources.yaml", tailscale)
    encrypted_secret_from_live(
        "tailscale", "operator-oauth", ts_dir / "operator-oauth.secret.yaml"
    )
    write_kustomization(
        ts_dir / "kustomization.yaml",
        ["resources.yaml", "operator-oauth.secret.yaml"],
    )

    # Preserve the exact currently installed NVIDIA Helm render as raw resources.
    nvidia = namespaced_resources("nvidia-device-plugin")
    nvidia.extend(
        [
            get_resource("clusterrole", "nvidia-device-plugin-role"),
            get_resource("clusterrolebinding", "nvidia-device-plugin-role-binding"),
        ]
    )
    nv_dir = ROOT / "infrastructure/olympus/nvidia-device-plugin"
    write_yaml_documents(nv_dir / "resources.yaml", nvidia)
    write_kustomization(nv_dir / "kustomization.yaml", ["resources.yaml"])


def export_apps() -> None:
    app_namespaces = [
        "homepage",
        "monitoring",
        "portainer",
        "pihole",
        "n8n",
        "uptime-kuma",
        "telchar-construct",
        "telchar-forge",
    ]
    apps = {namespace: namespaced_resources(namespace) for namespace in app_namespaces}

    cluster_objects = {
        "homepage": [
            ("clusterrole", "homepage"),
            ("clusterrolebinding", "homepage"),
        ],
        "monitoring": [
            ("clusterrole", "prometheus"),
            ("clusterrolebinding", "prometheus"),
            ("clusterrole", "kube-state-metrics"),
            ("clusterrolebinding", "kube-state-metrics"),
        ],
        "portainer": [
            ("clusterrolebinding", "portainer"),
            ("clusterrolebinding", "portainer-crb-clusteradmin"),
        ],
    }
    for namespace, refs in cluster_objects.items():
        apps[namespace].extend(get_resource(kind, name) for kind, name in refs)

    transform_sensitive_config(apps)

    secret_files: dict[str, list[str]] = {
        "monitoring": ["grafana-admin.secret.yaml"],
        "pihole": ["pihole-api-password.secret.yaml"],
        "telchar-construct": ["cloudflared-token.secret.yaml"],
        "telchar-forge": [
            "cloudflared-token.secret.yaml",
            "forge-secrets.secret.yaml",
            "ghcr-creds.secret.yaml",
        ],
    }
    encrypted_secret_from_live(
        "telchar-construct",
        "cloudflared-token",
        ROOT / "apps/olympus/telchar-construct/cloudflared-token.secret.yaml",
    )
    for secret_name in ("cloudflared-token", "forge-secrets", "ghcr-creds"):
        encrypted_secret_from_live(
            "telchar-forge",
            secret_name,
            ROOT / f"apps/olympus/telchar-forge/{secret_name}.secret.yaml",
        )

    for namespace, objects in apps.items():
        app_dir = ROOT / "apps/olympus" / namespace
        write_yaml_documents(app_dir / "resources.yaml", objects)
        write_kustomization(
            app_dir / "kustomization.yaml",
            ["resources.yaml", *secret_files.get(namespace, [])],
        )


def main() -> None:
    export_namespaces()
    export_infrastructure()
    export_apps()
    print("Exported normalized Olympus manifests; secret values were encrypted in-process.")


if __name__ == "__main__":
    main()
