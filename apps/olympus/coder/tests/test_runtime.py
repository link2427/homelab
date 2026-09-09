import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime', SOURCE / 'runtime/olympus-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.settings = patch.multiple(runtime, HOME=self.root / 'home', ROOT=self.root / 'tools',
                                       BASE=self.root / 'baseline', STATE=self.root / 'state')
        self.settings.start()
        runtime.HOME.mkdir()
        runtime.ROOT.mkdir()
        self.old = self.version('1.0.0')
        runtime.promote('codex', self.old)

    def tearDown(self):
        self.settings.stop()
        self.tmp.cleanup()

    def version(self, version, stamp=None):
        directory = runtime.ROOT / 'codex' / version
        (directory / 'bin').mkdir(parents=True)
        binary = directory / 'bin/codex'
        binary.write_text('#!/usr/bin/env python3\nimport time, os\nfrom pathlib import Path\nPath(os.environ["OLYMPUS_STATE"], "running").touch()\ntime.sleep(30)\n')
        binary.chmod(0o755)
        runtime.atomic_json(directory / 'ready.json', {'version': version, 'installed_at': stamp or version})
        return directory

    def test_registry_outage_keeps_current(self):
        with patch.object(runtime, 'latest', side_effect=TimeoutError('registry unavailable')):
            self.assertEqual(runtime.update(['codex']), 1)
        self.assertEqual(runtime.selected('codex'), self.old)

    def test_interrupted_install_keeps_current(self):
        with patch.object(runtime, 'latest', return_value=('1.1.0', {})), patch.object(runtime, 'install', side_effect=TimeoutError('interrupted')):
            self.assertEqual(runtime.update(['codex']), 1)
        self.assertEqual(runtime.selected('codex'), self.old)

    def test_success_selects_only_validated_candidate(self):
        new = self.version('1.1.0')
        with patch.object(runtime, 'latest', return_value=('1.1.0', {})), patch.object(runtime, 'install', return_value=new):
            self.assertEqual(runtime.update(['codex']), 0)
        self.assertEqual(runtime.selected('codex'), new)

    def test_major_migration_waits_for_explicit_adoption(self):
        new = self.version('2.0.0')
        with patch.object(runtime, 'latest', return_value=('2.0.0', {})), patch.object(runtime, 'install', return_value=new):
            runtime.update(['codex'])
        self.assertEqual(runtime.selected('codex'), self.old)
        runtime.adopt('codex')
        self.assertEqual(runtime.selected('codex'), new)

    def test_rollback_uses_previous_release_not_newer_staged_major(self):
        minor = self.version('1.1.0')
        runtime.promote('codex', minor)
        self.version('2.0.0')
        runtime.adopt('codex', rollback=True)
        self.assertEqual(runtime.selected('codex'), self.old)

    def test_stale_lock_file_does_not_block_update(self):
        runtime.STATE.mkdir()
        (runtime.STATE / 'update.lock').write_text('a dead process')
        with runtime.lock('update'):
            pass

    def test_reap_only_tagged_processes_across_process_groups(self):
        instance = 'isolated-lifecycle-test'
        children = [subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'],
                                    env={**os.environ, 'OLYMPUS_SERVICE_INSTANCE': tag}, start_new_session=True)
                    for tag in (instance, instance, 'unrelated-service')]
        try:
            runtime.reap_instance(instance)
            for child in children[:2]:
                self.assertEqual(child.wait(timeout=5), -9)
            self.assertIsNone(children[2].poll())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)

    def test_concurrent_update_does_not_install(self):
        with runtime.lock('update'), patch.object(runtime, 'latest') as latest:
            runtime.update(['codex'])
            latest.assert_not_called()

    def test_incomplete_or_broken_home_install_falls_back(self):
        fallback = runtime.BASE / 'codex/1.0.0'
        fallback.mkdir(parents=True)
        runtime.atomic_json(fallback / 'ready.json', {'version': '1.0.0'})
        (fallback.parent / 'current').symlink_to(fallback)
        (runtime.ROOT / 'codex/current').unlink()
        (runtime.ROOT / 'codex/current').symlink_to(runtime.ROOT / 'missing')
        self.assertEqual(runtime.selected('codex'), fallback)

    def test_invalid_version_never_becomes_a_path(self):
        with self.assertRaises(ValueError):
            runtime.install('codex', '../../escape', {'source': 'unused'})

    def test_low_disk_space_keeps_current(self):
        usage = type('Usage', (), {'free': 1024})()
        with patch.object(runtime.shutil, 'disk_usage', return_value=usage), self.assertRaises(RuntimeError):
            runtime.install('codex', '1.1.0', {'source': 'unused'})
        self.assertEqual(runtime.selected('codex'), self.old)

    def test_available_baseline_is_reused_without_installing_or_requiring_disk(self):
        prebuilt = runtime.BASE / 'codex/1.1.0'
        (prebuilt / 'bin').mkdir(parents=True)
        (prebuilt / 'bin/codex').write_text('validated image executable')
        runtime.atomic_json(prebuilt / 'ready.json', {'version': '1.1.0'})
        with patch.object(runtime, 'latest', return_value=('1.1.0', {})), \
                patch.object(runtime, 'run_checked', side_effect=AssertionError('No reinstall')), \
                patch.object(runtime.shutil, 'disk_usage', side_effect=AssertionError('No disk needed')):
            self.assertEqual(runtime.update(['codex']), 0)
        self.assertEqual(runtime.selected('codex'), prebuilt)
        self.assertFalse((runtime.ROOT / 'codex/1.1.0').exists())

    def test_checksum_failure(self):
        artifact = self.root / 'bad-binary'
        artifact.write_bytes(b'corrupted download')
        with patch.object(runtime.subprocess, 'run'), self.assertRaises(ValueError):
            runtime.download('https://example.invalid', artifact, '0' * 64)

    def test_session_lease_survives_exec_and_prevents_cleanup(self):
        env = {**os.environ, 'HOME': str(runtime.HOME), 'OLYMPUS_STATE': str(runtime.STATE),
               'OLYMPUS_TOOL_ROOT': str(runtime.ROOT), 'OLYMPUS_BASELINE': str(runtime.BASE)}
        process = subprocess.Popen([sys.executable, str(SOURCE / 'runtime/olympus-runtime.py'), 'run', 'codex'], env=env)
        try:
            deadline = time.monotonic() + 5
            while not (runtime.STATE / 'running').exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue((runtime.STATE / 'running').exists())
            self.assertIn('1.0.0', runtime.running_versions()['codex'])
            runtime.promote('codex', self.version('1.1.0'))
            newest = self.version('1.2.0')
            runtime.promote('codex', newest)
            runtime.cleanup('codex')
            self.assertTrue(self.old.exists(), 'Libraries of the running release were removed')
        finally:
            process.terminate()
            process.wait(timeout=5)
        runtime.cleanup('codex')
        self.assertFalse(self.old.exists())

    def test_configuration_backup_preserves_credentials_without_caches(self):
        config = runtime.HOME / '.codex'
        (config / 'node_modules').mkdir(parents=True)
        (config / 'auth.json').write_text('{"test": true}')
        (config / 'node_modules/cache').write_text('not valuable')
        backup = runtime.snapshot_config('codex')
        with tarfile.open(backup) as archive:
            self.assertIn('.codex/auth.json', archive.getnames())
            self.assertNotIn('.codex/node_modules/cache', archive.getnames())
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_recovery_names_are_unique_and_retained_count_is_bounded(self):
        backups = [runtime.snapshot_config('codex') for _ in range(7)]
        self.assertEqual(len(set(backups)), 7)
        self.assertEqual(len(list((runtime.STATE / 'recovery').glob('*.tar.gz'))), 5)


if __name__ == '__main__':
    unittest.main()
