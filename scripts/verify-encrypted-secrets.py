#!/usr/bin/env python3
"""Verify encrypted Git manifests reproduce the live Secret material."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
AGE_KEY_FILE = Path.home() / ".config" / "sops" / "age" / "keys.txt"


def command_json(command: list[str]) -> dict:
    result = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return json.loads(result.stdout)


def live_secret(namespace: str, name: str) -> dict:
    return command_json(["kubectl", "get", "secret", name, "-n", namespace, "-o", "json"])


def decrypt(path: Path) -> dict:
    environment = os.environ.copy()
    environment.setdefault("SOPS_AGE_KEY_FILE", str(AGE_KEY_FILE))
    result = subprocess.run(
        ["sops", "--decrypt", str(path)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=environment,
    )
    return yaml.safe_load(result.stdout)


def secret_data(secret: dict) -> dict[str, str]:
    data = dict(secret.get("data", {}))
    for key, value in secret.get("stringData", {}).items():
        data[key] = base64.b64encode(value.encode("utf-8")).decode("ascii")
    return data


def main() -> None:
    live_mappings = {
        ROOT / "infrastructure/olympus/tailscale-operator/operator-oauth.secret.yaml": (
            "tailscale",
            "operator-oauth",
        ),
        ROOT / "apps/olympus/telchar-construct/cloudflared-token.secret.yaml": (
            "telchar-construct",
            "cloudflared-token",
        ),
        ROOT / "apps/olympus/telchar-forge/cloudflared-token.secret.yaml": (
            "telchar-forge",
            "cloudflared-token",
        ),
        ROOT / "apps/olympus/telchar-forge/forge-secrets.secret.yaml": (
            "telchar-forge",
            "forge-secrets",
        ),
        ROOT / "apps/olympus/telchar-forge/ghcr-creds.secret.yaml": (
            "telchar-forge",
            "ghcr-creds",
        ),
        ROOT / "apps/olympus/monitoring/grafana-admin.secret.yaml": (
            "monitoring",
            "grafana-admin",
        ),
        ROOT / "apps/olympus/pihole/pihole-api-password.secret.yaml": (
            "pihole",
            "pihole-api-password",
        ),
    }
    for path, (namespace, name) in live_mappings.items():
        expected = live_secret(namespace, name)
        actual = decrypt(path)
        assert secret_data(actual) == expected.get("data", {}), path
        assert actual.get("type", "Opaque") == expected.get("type", "Opaque"), path
        print(f"verified {path.relative_to(ROOT)}")

    grafana = command_json(
        ["kubectl", "get", "deployment", "grafana", "-n", "monitoring", "-o", "json"]
    )
    grafana_password = next(
        env
        for container in grafana["spec"]["template"]["spec"]["containers"]
        for env in container.get("env", [])
        if env.get("name") == "GF_SECURITY_ADMIN_PASSWORD"
    )
    assert "value" not in grafana_password
    assert grafana_password["valueFrom"]["secretKeyRef"] == {
        "name": "grafana-admin",
        "key": "admin-password",
    }
    print("verified Grafana uses its encrypted-source Secret")

    pihole = command_json(
        ["kubectl", "get", "configmap", "pihole-env", "-n", "pihole", "-o", "json"]
    )
    assert "FTLCONF_webserver_api_password" not in pihole.get("data", {})
    pihole_deployment = command_json(
        ["kubectl", "get", "deployment", "pihole", "-n", "pihole", "-o", "json"]
    )
    pihole_password = next(
        env
        for container in pihole_deployment["spec"]["template"]["spec"]["containers"]
        for env in container.get("env", [])
        if env.get("name") == "FTLCONF_webserver_api_password"
    )
    assert pihole_password["valueFrom"]["secretKeyRef"] == {
        "name": "pihole-api-password",
        "key": "FTLCONF_webserver_api_password",
    }
    print("verified Pi-hole uses its encrypted-source Secret")


if __name__ == "__main__":
    main()
