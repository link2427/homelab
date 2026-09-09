"""Run inside an offline, unprivileged canary container after runtime init."""
import json
import http.cookiejar
import http.client
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
if os.environ.get('OLYMPUS_CODER_WORKSPACE'):
    suffix = f"{os.environ['OLYMPUS_CODER_WORKSPACE']}--{os.environ['OLYMPUS_CODER_OWNER']}.{os.environ['OLYMPUS_CODER_WILDCARD_DOMAIN']}"
    for host in ('deepseek--' + suffix, 'deepseek--' + os.environ['OLYMPUS_CODER_AGENT'] + '--' + suffix):
        connection = http.client.HTTPConnection('127.0.0.1', 13340, timeout=5)
        connection.request('GET', '/', headers={'Host': host, 'Origin': 'https://' + host})
        response = connection.getresponse()
        assert response.status in (200, 302, 303), f'Coder app host rejected: {response.status}'
        assert 'httponly' in response.getheader('Set-Cookie', '').lower(), 'Missing normal DeepSeek login cookie'
        response.read(); connection.close()
    connection = http.client.HTTPConnection('127.0.0.1', 13340, timeout=5)
    connection.request('GET', '/', headers={'Host': 'unrelated.example.com'})
    assert connection.getresponse().status == 403, 'Unexpected application host accepted'
    connection.close()
    print('DeepSeek accepts both Coder app URL forms and rejects unrelated hosts.')
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
