#!/usr/bin/env python3
import json
import os
import re
from pathlib import Path

reasonix_home = Path("/home/coder/.reasonix")
reasonix_home.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(reasonix_home, 0o700)

# Talos keeps unprivileged user namespaces disabled and the Coder namespace
# enforces the Kubernetes Baseline policy, so Bubblewrap cannot create its
# nested namespace. Keep Reasonix's Bash tool usable while the outer Coder
# pod remains non-root, capability-free, and protected by RuntimeDefault
# seccomp. File writer tools still honor Reasonix's workspace-root policy.
config = reasonix_home / "config.toml"
if config.exists():
    content = config.read_text(encoding="utf-8")
    section = re.search(r"(?ms)^\[sandbox\]\s*\n(?P<body>.*?)(?=^\[|\Z)", content)
    if section:
        body = section.group("body")
        if re.search(r"(?m)^\s*bash\s*=", body):
            updated_body = re.sub(
                r'(?m)^\s*bash\s*=.*$',
                'bash = "off"',
                body,
                count=1,
            )
        else:
            updated_body = body + 'bash = "off"\n'
        content = content[:section.start("body")] + updated_body + content[section.end("body"):]
    else:
        content = content.rstrip() + '\n\n[sandbox]\nbash = "off"\nnetwork = true\n'
else:
    content = '[sandbox]\nbash = "off"\nnetwork = true\n'

config_tmp = reasonix_home / "config.toml.coder.tmp"
config_tmp.write_text(content, encoding="utf-8")
os.chmod(config_tmp, 0o600)
os.replace(config_tmp, config)

key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
if key:
    credentials = reasonix_home / ".env"
    retained = []
    if credentials.exists():
        for line in credentials.read_text(encoding="utf-8").splitlines():
            normalized = line.strip()
            if normalized.startswith("DEEPSEEK_API_KEY="):
                continue
            if normalized.startswith("export DEEPSEEK_API_KEY="):
                continue
            retained.append(line)

    retained.append(f"DEEPSEEK_API_KEY={key}")
    temporary = reasonix_home / ".env.coder.tmp"
    temporary.write_text("\n".join(retained) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, credentials)

    prime_home = Path("/home/coder/.prime/agent")
    prime_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(prime_home, 0o700)
    prime_auth = prime_home / "auth.json"
    try:
        auth = json.loads(prime_auth.read_text(encoding="utf-8")) if prime_auth.exists() else {}
    except (json.JSONDecodeError, OSError):
        auth = {}
    if not isinstance(auth, dict):
        auth = {}
    auth["deepseek"] = {"type": "api_key", "key": "DEEPSEEK_API_KEY"}
    prime_auth_tmp = prime_home / "auth.json.coder.tmp"
    prime_auth_tmp.write_text(json.dumps(auth, indent=2) + "\n", encoding="utf-8")
    os.chmod(prime_auth_tmp, 0o600)
    os.replace(prime_auth_tmp, prime_auth)
