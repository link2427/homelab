#!/usr/bin/env python3
"""Publish deterministic Coder template bundles. Never modify workspace builds."""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

SOURCE = Path(__file__).resolve().parents[1]
ORG = "733fbb74-0275-445b-a92d-c50ff12bbbbf"
NAMES = ("olympus-linux", "olympus-agent", "olympus-gpu", "olympus-build", "container-forge")


def request(url, token, method="GET", body=None, coder=False, content_type="application/json"):
    headers = {"User-Agent": "Olympus-Coder-Catalog/1", "Accept": "application/json"}
    headers["Coder-Session-Token" if coder else "Authorization"] = token if coder else "Bearer " + token
    if body is not None:
        headers["Content-Type"] = content_type
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=90) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


class Coder:
    def __init__(self, url=None, token=None):
        self.url = (url or os.environ.get("CODER_URL", "https://coder.jacob-neel.dev")).rstrip('/')
        self.token = token or os.environ["CODER_SESSION_TOKEN"]

    def api(self, path, method="GET", body=None, content_type="application/json"):
        return request(self.url + '/api/v2' + path, self.token, method, body, True, content_type)


def github_token():
    if os.environ.get("GITHUB_APP_PRIVATE_KEY_FILE"):
        import jwt
        key = Path(os.environ["GITHUB_APP_PRIVATE_KEY_FILE"]).read_text()
        stamp = int(time.time())
        bearer = jwt.encode({"iat": stamp - 60, "exp": stamp + 540, "iss": os.environ["GITHUB_APP_ID"]}, key, algorithm="RS256")
        installation = os.environ["GITHUB_INSTALLATION_ID"]
        result = request(f'https://api.github.com/app/installations/{installation}/access_tokens', bearer,
                         'POST', {"permissions": {"metadata": "read"}})
        return result['token'], True
    if os.environ.get("GH_TOKEN"):
        return os.environ["GH_TOKEN"], False
    result = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True, check=True)
    return result.stdout.strip(), False


def catalog(repositories, owner, archived=False):
    result = []
    for repo in repositories:
        if repo['owner']['login'].lower() != owner.lower() or (repo['archived'] and not archived):
            continue
        result.append({"name": repo['full_name'], "url": repo['html_url'].rstrip('/') + '.git',
                       "visibility": "private" if repo['private'] else "public", "archived": bool(repo['archived']),
                       "fork": bool(repo['fork']), "description": repo.get('description') or ''})
    return sorted(result, key=lambda item: item['name'].lower())


def get_catalog(owner, archived=False):
    token, installation = github_token()
    repos = []
    for page in range(1, 1001):
        endpoint = f'/installation/repositories?per_page=100&page={page}' if installation else f'/user/repos?affiliation=owner&per_page=100&page={page}'
        data = request('https://api.github.com' + endpoint, token)
        chunk = data['repositories'] if installation else data
        repos.extend(chunk)
        if len(chunk) < 100:
            break
    else:
        raise RuntimeError('Repository pagination exceeded its bound')
    entries = catalog(repos, owner, archived)
    if not entries:
        raise RuntimeError('Empty catalog refused; check GitHub App installation access')
    return entries


def bundle(directory):
    files = {}
    for pattern in ('*.tf', '*.tftpl'):
        for path in directory.glob(pattern):
            files[path.name] = path.read_bytes().replace(b'\r\n', b'\n')
    for path in (SOURCE / 'runtime/module').glob('*.tf'):
        files['runtime/' + path.name] = path.read_bytes().replace(b'\r\n', b'\n')
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as archive:
        for name, body in sorted(files.items()):
            entry = tarfile.TarInfo(name)
            entry.size = len(body)
            entry.mode = 0o644
            archive.addfile(entry, io.BytesIO(body))
    return stream.getvalue()


def variables(name, entries, images, owner):
    shared = {"github_owner": owner, "github_repositories_json": json.dumps(entries[:60], separators=(',', ':'))}
    if name == 'container-forge':
        shared.update(namespace='coder-forge', workspace_image=images['workspace'],
                      kaniko_image='ghcr.io/osscontainertools/kaniko:v1.28.2-alpine@sha256:44f90ae1ba366aeedbd0f2d56dbe246354553e47904338dd9321a41a44bea9ff',
                      kubectl_version='v1.35.2', build_node='atlas')
    else:
        profile = name.removeprefix('olympus-')
        image = images['workspace'] if profile == 'agent' else images[profile]
        shared.update(profile=profile, image=image)
        shared['recovery_home_pvc'] = images.get('canary_home_pvc', '') if profile == 'agent' else ''
    return shared


def fingerprint(archive, values):
    return hashlib.sha256(archive + json.dumps(values, sort_keys=True, separators=(',', ':')).encode()).hexdigest()[:20]


def wait_import(client, version):
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        data = client.api('/templateversions/' + version['id'])
        state = data['job']['status']
        if state == 'succeeded':
            return data
        if state in ('failed', 'canceled'):
            # Server details can contain private repository values. Keep them in Coder.
            raise RuntimeError(f'Template import {version["id"]} {state}; inspect its Coder logs')
        time.sleep(3)
    raise TimeoutError('Template import did not finish within ten minutes')


def publish(client, name, entries, images, owner, activate=True, target_name=None):
    target_name = target_name or name
    archive = bundle(SOURCE / ('container-forge' if name == 'container-forge' else 'template'))
    values = variables(name, entries, images, owner)
    version_name = 'managed-' + fingerprint(archive, values)
    try:
        template = client.api(f'/organizations/{ORG}/templates/{target_name}')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        template = None
    version = None
    if template:
        try:
            version = client.api(f'/templates/{template["id"]}/versions/{version_name}')
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        if version and version['job']['status'] in ('failed', 'canceled'):
            # A transient import failure must be retryable without source changes.
            version_name += '-' + str(int(time.time()))
            version = None
    if not version:
        upload = client.api('/files', 'POST', archive, 'application/x-tar')
        body = {"name": version_name, "storage_method": "file", "file_id": upload['id'],
                "provisioner": "terraform", "message": "Managed Olympus runtime and repository catalog",
                "user_variable_values": [{"name": key, "value": value} for key, value in values.items()],
                "tags": {"scope": "organization", "owner": ""}}
        if template:
            body['template_id'] = template['id']
        version = client.api(f'/organizations/{ORG}/templateversions', 'POST', body)
    version = wait_import(client, version)
    if not template:
        template = client.api(f'/organizations/{ORG}/templates', 'POST', {
            'name': target_name, 'display_name': target_name.replace('-', ' ').title(),
            'version_id': version['id'], 'default_ttl_ms': 0,
            'description': 'Olympus workspace with persistent home storage', 'icon': '/icon/code.svg'})
    elif activate and template['active_version_id'] != version['id']:
        client.api(f'/templates/{template["id"]}/versions', 'PATCH', {'id': version['id']})
    print(f'{target_name}: {version_name} ' + ('active' if activate else 'validated, awaiting canary promotion'), flush=True)
    return {'template': target_name, 'template_id': template['id'], 'version_id': version['id'], 'version_name': version_name,
            'active': activate, 'catalog_count': len(entries), 'checked_at': dt.datetime.now(dt.timezone.utc).isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner', default='link2427')
    parser.add_argument('--include-archived', action='store_true')
    parser.add_argument('--images', type=Path, default=SOURCE / 'publisher/images.json')
    parser.add_argument('--canary', action='store_true')
    parser.add_argument('--canary-home-pvc', help='Already cloned same-namespace PVC for a private Agent recovery canary')
    parser.add_argument('--only', choices=NAMES)
    parser.add_argument('--bundle-dir', type=Path)
    args = parser.parse_args()
    if args.bundle_dir:
        args.bundle_dir.mkdir(parents=True, exist_ok=True)
        for name in ('template', 'container-forge'):
            dest = args.bundle_dir / name
            dest.mkdir(exist_ok=True)
            with tarfile.open(fileobj=io.BytesIO(bundle(SOURCE / name))) as archive:
                archive.extractall(dest, filter='data')
        return
    images = json.loads(args.images.read_text())
    if args.canary_home_pvc:
        if not args.canary:
            parser.error('--canary-home-pvc requires --canary')
        images['canary_home_pvc'] = args.canary_home_pvc
    if not re.fullmatch(r'.+@sha256:[a-f0-9]{64}', images['workspace']):
        raise RuntimeError('A verified immutable workspace image is required before publishing')
    entries = get_catalog(args.owner, args.include_archived)
    client = Coder()
    results = []
    for name in ([args.only] if args.only else NAMES):
        if args.canary and name not in ('olympus-agent', 'container-forge'):
            continue
        activate = args.canary or name not in ('olympus-agent', 'container-forge') or images['promote_runtime']
        results.append(publish(client, name, entries, images, args.owner, activate,
                               name + '-canary' if args.canary else None))
    output = Path(os.environ.get('PUBLISH_STATUS_FILE', '/tmp/publisher-status.json'))
    output.write_text(json.dumps(results, indent=2) + '\n')
    print(f'Catalog refresh succeeded: {len(entries)} repositories; {len(results)} templates checked.')


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f'Publisher API request failed: HTTP {error.code}; previous templates retained.')
