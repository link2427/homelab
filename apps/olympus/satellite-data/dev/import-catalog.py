"""One-time dev catalog reuse during a shared CelesTrak cooldown.

Input is the checksum-verified, still-fresh published S3 database. Only Satellites
and LastUpdates are refreshed; all launch/history/cursor/cache data stays local.
This is NOT a Horizons regeneration or publication success marker.
"""
import datetime as dt
import fcntl
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import time

root = Path('/data/dev')
source = Path(sys.argv[1])
provenance = json.loads(Path(sys.argv[2]).read_text())
deadline = time.monotonic() + 300
while not source.with_suffix('.ready').exists():
    if time.monotonic() > deadline:
        raise TimeoutError('Verified input was not supplied; dev state left unchanged')
    time.sleep(1)
assert hashlib.sha256(source.read_bytes()).hexdigest() == provenance['sha256']
with (root/'publisher.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    target = json.loads((root/'publisher-target.json').read_text())
    assert target['environment'] == 'dev' and target['provider'] == 'r2'
    status = json.loads((root/'status.json').read_text())
    backup = Path(status['migration_backup'])
    assert (backup/'manifest.json').is_file() and (backup/'working.db').is_file()
    with sqlite3.connect((root/'working.db').as_uri(), uri=True) as db:
        # This is a closed, checksummed export, not a live WAL database.
        db.execute('ATTACH DATABASE ? AS incoming', (source.as_uri()+'?mode=ro&immutable=1',))
        assert db.execute('PRAGMA incoming.integrity_check').fetchone()[0] == 'ok'
        updated = db.execute('SELECT MAX(LastUpdated) FROM incoming.LastUpdates').fetchone()[0]
        age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(updated).replace(tzinfo=dt.timezone.utc)
        assert dt.timedelta() <= age < dt.timedelta(hours=26), 'Source catalog no longer meets freshness gate'
        count = db.execute('SELECT COUNT(*) FROM incoming.Satellites').fetchone()[0]
        assert count >= db.execute('SELECT COUNT(*) FROM Satellites').fetchone()[0] * .8
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
                  if r[0] not in ('Satellites', 'LastUpdates', 'sqlite_sequence')]
        def protected():
            return {table: hashlib.sha256(json.dumps(db.execute('SELECT * FROM "'+table+'" ORDER BY rowid').fetchall()).encode()).hexdigest()
                    for table in tables}
        before = protected()
        db.execute('BEGIN IMMEDIATE')
        for table in ('Satellites', 'LastUpdates'):
            assert db.execute(f'PRAGMA table_info({table})').fetchall() == db.execute(f'PRAGMA incoming.table_info({table})').fetchall()
            db.execute(f'DELETE FROM {table}')
            db.execute(f'INSERT INTO {table} SELECT * FROM incoming.{table}')
        assert before == protected(), 'An unrelated table changed'
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert not db.execute('PRAGMA foreign_key_check').fetchall()
    report = {'source_sha256': provenance['sha256'], 'source_url': provenance['url'],
              'satellites_updated_at': updated, 'satellite_count': count,
              'protected_tables_unchanged': before,
              'state_files_unchanged': {str(p.relative_to(root/'state')): hashlib.sha256(p.read_bytes()).hexdigest()
                                        for p in (root/'state').rglob('*') if p.is_file()}}
    (root/'catalog-reuse.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)
