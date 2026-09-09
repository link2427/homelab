#!/usr/bin/env python3
"""Add the Grok ACP profile without changing the user's selected agent or tasks."""
import json
from pathlib import Path
import time
import urllib.error
import urllib.request


def configure():
    key_path = Path.home() / '.openhands/agent-canvas/api-key.txt'
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            key = key_path.read_text().strip()
            def api(path, body=None):
                request = urllib.request.Request('http://127.0.0.1:13342' + path,
                    data=json.dumps(body).encode() if body is not None else None,
                    headers={'X-Session-API-Key': key, 'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=10) as response:
                    return json.load(response)
            profiles = api('/api/agent-profiles')['profiles']
            if not any(p['name'] == 'Grok-Build' for p in profiles):
                api('/api/agent-profiles/Grok-Build', {'agent_kind': 'acp',
                    'acp_server': 'custom', 'acp_command': '/opt/olympus/bin/grok agent stdio',
                    'acp_model': None})
            print('Grok-Build profile ready in OpenHands. Select it when starting a conversation.')
            return
        except (OSError, ValueError):
            time.sleep(2)
    raise RuntimeError('OpenHands profile setup timed out; existing settings were retained')


if __name__ == '__main__':
    configure()
