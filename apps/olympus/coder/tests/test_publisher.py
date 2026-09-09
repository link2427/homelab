import importlib.util
import io
from pathlib import Path
import tarfile
import unittest
import urllib.error
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publisher', SOURCE / 'publisher/publish.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def repo(name, **changes):
    return {'owner': {'login': 'link2427'}, 'full_name': 'link2427/' + name,
            'html_url': 'https://github.com/link2427/' + name, 'private': True,
            'archived': False, 'fork': False, 'description': None, **changes}


class PublisherTests(unittest.TestCase):
    def test_catalog_ignores_activity_and_api_order(self):
        a = publisher.catalog([repo('Zed', pushed_at='2026-01-01'), repo('Alpha')], 'link2427')
        b = publisher.catalog([repo('Alpha'), repo('Zed', pushed_at='2026-09-09')], 'link2427')
        self.assertEqual(a, b)

    def test_archive_and_owner_filter(self):
        entries = publisher.catalog([repo('one'), repo('old', archived=True), repo('foreign', owner={'login': 'someone'})], 'link2427')
        self.assertEqual(len(entries), 1)

    def test_more_than_sixty_repositories_does_not_break_publication(self):
        entries = publisher.catalog([repo('project' + str(i)) for i in range(80)], 'link2427')
        data = publisher.variables('olympus-agent', entries, {'workspace': 'image'}, 'link2427')
        import json
        self.assertEqual(len(json.loads(data['github_repositories_json'])), 60)

    def test_bundle_is_deterministic_and_contains_shared_module(self):
        first = publisher.bundle(SOURCE / 'template')
        self.assertEqual(first, publisher.bundle(SOURCE / 'template'))
        with tarfile.open(fileobj=io.BytesIO(first)) as archive:
            self.assertIn('runtime/main.tf', archive.getnames())
            self.assertTrue(archive.getmember('runtime').isdir())
            self.assertTrue(all(item.name.endswith(('.tf', '.tftpl')) for item in archive.getmembers() if item.isfile()))

    def test_fingerprint_changes_only_for_meaningful_input(self):
        self.assertEqual(publisher.fingerprint(b'code', {'b': 2, 'a': 1}), publisher.fingerprint(b'code', {'a': 1, 'b': 2}))
        self.assertNotEqual(publisher.fingerprint(b'code', {'a': 1}), publisher.fingerprint(b'code', {'a': 2}))

    def test_unchanged_template_has_no_writes_or_workspace_requests(self):
        class Client:
            def api(self, path, method='GET', body=None, content_type=None):
                self_test.assertEqual(method, 'GET')
                self_test.assertNotIn('/workspaces', path)
                if path.startswith('/organizations/'):
                    return {'id': 'template', 'active_version_id': 'version'}
                return {'id': 'version', 'job': {'status': 'succeeded'}}
        self_test = self
        publisher.publish(Client(), 'olympus-agent', [], {'workspace': 'image'}, 'link2427')

    def test_failed_import_never_activates_template(self):
        calls = []
        class Client:
            def api(self, path, method='GET', body=None, content_type=None):
                calls.append((path, method))
                if path.startswith('/organizations/'):
                    return {'id': 'template', 'active_version_id': 'old'}
                return {'id': 'candidate', 'job': {'status': 'pending'}}
        with patch.object(publisher, 'wait_import', side_effect=RuntimeError('import failed')):
            with self.assertRaises(RuntimeError):
                publisher.publish(Client(), 'olympus-agent', [], {'workspace': 'image'}, 'link2427')
        self.assertTrue(all(method == 'GET' for _,method in calls))

    def test_new_import_uses_coder_file_hash_response(self):
        calls = []
        class Client:
            def api(self, path, method='GET', body=None, content_type=None):
                calls.append((path,method,body))
                if path == '/files': return {'hash': 'uploaded-file-id'}
                if method == 'POST':
                    self_test.assertEqual(body['file_id'], 'uploaded-file-id')
                    return {'id': 'candidate', 'job': {'status': 'pending'}}
                if path.startswith('/organizations/'):
                    return {'id':'template','active_version_id':'old'}
                if '/templates/' in path:
                    raise urllib.error.HTTPError(path,404,'not found',None,None)
                return {'id':'candidate','job':{'status':'succeeded'}}
        self_test = self
        publisher.publish(Client(), 'olympus-agent', [], {'workspace':'image'}, 'link2427', activate=False)
        self.assertFalse(any(method == 'PATCH' for _,method,_ in calls))

    def test_canary_creation_is_private_and_uses_template_version_id(self):
        calls = []
        class Client:
            def api(self, path, method='GET', body=None, content_type=None):
                calls.append((path,method,body))
                if path == '/files': return {'hash':'file'}
                if method == 'POST' and path.endswith('/templateversions'):
                    return {'id':'candidate','job':{'status':'pending'}}
                if method == 'POST': return {'id':'private-canary'}
                if path.startswith('/organizations/'):
                    raise urllib.error.HTTPError(path,404,'not found',None,None)
                return {'id':'candidate','job':{'status':'succeeded'}}
        publisher.publish(Client(), 'olympus-agent', [], {'workspace':'image'}, 'link2427',
                          target_name='olympus-agent-canary')
        body = next(body for path,method,body in calls if method == 'POST' and path.endswith('/templates'))
        self.assertEqual(body['template_version_id'], 'candidate')
        self.assertTrue(body['disable_everyone_group_access'])

    def test_missing_production_template_cannot_bypass_canary_gate(self):
        class Client:
            def api(self, path, method='GET', body=None, content_type=None):
                if method != 'GET': raise AssertionError('Gate must refuse before any writes')
                raise urllib.error.HTTPError(path,404,'not found',None,None)
        with self.assertRaisesRegex(RuntimeError, 'canary promotion'):
            publisher.publish(Client(), 'olympus-agent', [], {'workspace':'image'}, 'link2427', activate=False)

    def test_canary_gate_preserves_active_production_version(self):
        calls = []
        class Client:
            def api(self, path, method='GET', body=None, content_type=None):
                calls.append((path, method))
                if path.startswith('/organizations/'):
                    return {'id': 'template', 'active_version_id': 'old'}
                return {'id': 'candidate', 'job': {'status': 'succeeded'}}
        publisher.publish(Client(), 'olympus-agent', [], {'workspace': 'image'}, 'link2427', activate=False)
        self.assertTrue(all(method == 'GET' for _,method in calls))


if __name__ == '__main__':
    unittest.main()
