"""Stage an independently qualified snapshot on the existing, idle publisher PVC.

Run once with the CronJob suspended. This never calls any ingestion provider.
Production integrates only Horizons tables after proving other rows are current.
"""
from contextlib import closing
import datetime as dt
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import urllib.error

sys.path.insert(0, '/app/scripts')
import local_publisher as publisher

HORIZONS = ('CelestialBodyMetadata', 'SpacecraftMetadata', 'CelestialEphemerisSamples',
            'CelestialOrbitEphemerisSamples', 'SpacecraftEphemerisSamples')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inventory(path):
    with closing(sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)) as db:
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok' or db.execute('PRAGMA foreign_key_check').fetchone():
            raise ValueError('SQLite integrity or foreign key failure')
        result = {}
        for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall():
            escaped = '"' + table.replace('"', '""') + '"'
            columns = len(db.execute('PRAGMA table_info(' + escaped + ')').fetchall())
            rows = db.execute('SELECT * FROM ' + escaped + ' ORDER BY ' + ','.join(str(i) for i in range(1, columns+1))).fetchall()
            result[table] = {'count': len(rows), 'sha256': hashlib.sha256(json.dumps(rows, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()}
        return result


def state_hashes(root):
    return {str(p.relative_to(root)): digest(p) for p in sorted((root / 'state').rglob('*')) if p.is_file()}


def stage(config, source, metadata, integrate_horizons=False, backup_s3=False):
    root = Path(config['root']).resolve()
    expected_root = Path('/data') / config['environment']
    if root != expected_root or not (root / 'publisher.lock').is_file():
        raise ValueError('Expected existing environment root and publisher lock')
    if integrate_horizons and config['environment'] != 'prod':
        raise ValueError('Working integration is reserved for the reviewed production release')
    if digest(source) != metadata['sha256'] or source.stat().st_size != metadata['size_bytes']:
        raise ValueError('Qualified snapshot identity mismatch')
    with (root / 'publisher.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target = {'environment': config['environment'], **config['storage']}
        if json.loads((root / 'publisher-target.json').read_text()) != target:
            raise ValueError('Existing storage target differs')
        for name in ('working.db', 'candidate.db', 'baseline.db', 'status.json'):
            if not (root / name).is_file():
                raise ValueError('Existing publisher state is required: ' + name)
        status = json.loads((root / 'status.json').read_text())
        if status.get('pending_delivery') or status.get('state') in ('running', 'validating') or status.get('operator_required'):
            raise ValueError('An unfinished operation requires review before staging')
        before = inventory(root / 'working.db')
        incoming = inventory(source)
        protected = {t: v for t, v in before.items() if t not in HORIZONS}
        if integrate_horizons and protected != {t: v for t, v in incoming.items() if t not in HORIZONS}:
            raise ValueError('Working non-Horizons rows advanced or differ; replay on current state first')
        validation = publisher.validate(source, root / 'baseline.db', cache_directory=root / 'state/celestrak')
        states = state_hashes(root)
        working_sha = digest(root / 'working.db')
        backup = root / 'backups' / ('before-release-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        backup.mkdir(parents=True)
        files = [p for p in root.rglob('*') if p.is_file() and p.relative_to(root).parts[0] != 'backups'
                 and p.name != 'publisher.lock' and not p.name.endswith(('-wal', '-shm'))]
        for path in files:
            destination = backup / path.relative_to(root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if path.suffix == '.db':
                publisher.snapshot(path, destination)
                if inventory(path) != inventory(destination):
                    raise ValueError('Backup row verification failed: ' + path.name)
            else:
                shutil.copy2(path, destination)
                if digest(path) != digest(destination):
                    raise ValueError('Backup hash verification failed: ' + path.name)
        hashes = {str(p.relative_to(backup)): digest(p) for p in backup.rglob('*') if p.is_file()}
        publisher.write_json(backup / 'manifest.json', {'files': hashes, 'state_hashes': states, 'working_tables': before})
        rollback_receipt = None
        if backup_s3:
            if config['environment'] != 'prod' or config['storage']['bucket'] != 'cosmotrak-data':
                raise ValueError('Legacy backup is production S3 only')
            legacy = publisher.S3(config)
            old_key = status['published_key']
            old_data = legacy.request(key=old_key)
            old_sha = hashlib.sha256(old_data).hexdigest()
            if old_sha != status['sha256']:
                raise ValueError('Current S3 bytes differ from the production receipt')
            backup_key = old_key[:-3] + '-before-' + old_sha + '.db'
            try:
                legacy.request('PUT', backup_key, data=old_data, extra={'if-none-match': '*', 'content-type': 'application/vnd.sqlite3'})
            except urllib.error.HTTPError as error:
                if error.code != 412:
                    raise
            if hashlib.sha256(legacy.request(key=backup_key)).hexdigest() != old_sha:
                raise ValueError('Legacy S3 rollback checksum mismatch')
            rollback_receipt = {'bucket': 'cosmotrak-data', 'original_key': old_key, 'backup_key': backup_key,
                                'sha256': old_sha, 'size_bytes': len(old_data), 'download_verified': True}
            publisher.write_json(backup / 'legacy-s3-rollback.json', rollback_receipt)
        if integrate_horizons:
            with closing(sqlite3.connect(root / 'working.db')) as db:
                db.execute('PRAGMA foreign_keys=ON')
                db.execute('ATTACH DATABASE ? AS incoming', (str(source),))
                with db:
                    for table in reversed(HORIZONS):
                        db.execute('DELETE FROM main.' + table)
                    for table in HORIZONS:
                        db.execute('INSERT INTO main.' + table + ' SELECT * FROM incoming.' + table)
                    if db.execute('PRAGMA foreign_key_check').fetchone():
                        raise ValueError('Integrated Horizons foreign key failure')
            after = inventory(root / 'working.db')
            if after != incoming:
                raise ValueError('Integrated working table inventory differs from qualified snapshot')
        else:
            if inventory(root / 'working.db') != before or digest(root / 'working.db') != working_sha:
                raise ValueError('Development working database changed')
        shutil.copyfile(source, root / 'candidate.incoming')
        if digest(root / 'candidate.incoming') != metadata['sha256']:
            raise ValueError('Staged copy checksum mismatch')
        (root / 'candidate.incoming').replace(root / 'candidate.db')
        publisher.write_json(root / 'candidate.json', metadata)
        if state_hashes(root) != states or json.loads((root / 'status.json').read_text()) != status:
            raise ValueError('Provider state or publisher schedule changed while staging')
        report = {'status': 'STAGED', 'environment': config['environment'], 'metadata': metadata,
                  'backup': str(backup), 'backup_files': len(hashes), 'provider_state_hashes': states,
                  'working_sha256_before': working_sha, 'working_tables_before': before,
                  'working_tables_after': inventory(root / 'working.db'), 'horizons_integrated': integrate_horizons,
                  'protected_status': {k: status.get(k) for k in ('last_attempt','last_ingested','next_attempt','next_ingestion_due','retry_not_before')},
                  'legacy_s3_rollback': rollback_receipt, 'validation': validation, 'ingestion_requests': 0}
        publisher.write_json(root / 'release-staging.json', report)
        print(json.dumps({'status': 'STAGED', 'backup': str(backup), 'backup_files': len(hashes),
                          'sha256': metadata['sha256'], 'horizons_integrated': integrate_horizons, 'ingestion_requests': 0}), flush=True)
        return report


if __name__ == '__main__':
    config = publisher.configuration(json.loads(Path(sys.argv[1]).read_text()), publish=True)
    release = json.loads(Path(sys.argv[2]).read_text())
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / 'qualified.db'
        storage_config = config if config['environment'] == 'dev' else config['modern']
        source.write_bytes(publisher.S3(storage_config).request(key=release['source_key']))
        stage(config, source, release['metadata'], release.get('integrate_horizons', False), release.get('backup_s3', False))
