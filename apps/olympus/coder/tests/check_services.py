"""Run inside an offline, unprivileged canary container after runtime init."""
import json
import http.cookiejar
import os
from pathlib import Path
import subprocess
import time
import urllib.request

deadline = time.monotonic() + 90
ports = {'editor': (13337, '/healthz'), 'exports': (13339, '/'),
         'reasonix': (8787, '/'), 'deepseek': (13340, '/'), 'openhands': (13341, '/')}
pending = dict(ports)
pending['openhands-backend'] = (13342, '/health')
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
while pending and time.monotonic() < deadline:
    for name, (port, path) in list(pending.items()):
        try:
            with opener.open(f'http://127.0.0.1:{port}{path}', timeout=2) as response:
                if response.status == 200:
                    print(name + ': HTTP 200', flush=True)
                    del pending[name]
        except Exception:
            pass
    if pending:
        time.sleep(1)
if pending:
    for name in pending:
        path = Path.home() / '.local/state/olympus/logs' / (name + '.log')
        import re
        print(name, re.sub(r'([?&]token=)[^\s&]+', r'\1[redacted]', path.read_text()[-3500:]) if path.exists() else 'no log')
    raise SystemExit('Unhealthy services: ' + ', '.join(pending))
while time.monotonic() < deadline:
    status = subprocess.run(['/opt/olympus/bin/olympus-services', 'status'], capture_output=True, text=True)
    lines = status.stdout.strip().splitlines()
    if status.returncode == 0 and len(lines) == 5 and all(' RUNNING ' in line for line in lines):
        break
    time.sleep(1)
else:
    raise SystemExit('Supervisor did not recover every service: ' + status.stdout)
subprocess.run(['/opt/olympus/bin/olympus-doctor'], check=True)
print('All browser services start without Internet access.')
