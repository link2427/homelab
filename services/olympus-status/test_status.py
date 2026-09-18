import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import collector
import server

NOW = 1789700000
POISON = "PRIVATE_TOKEN_serial_ip_repo_command"


def fixture():
    raw = {key: [] for key in [*collector.SOURCES, "hardware"]}
    raw["nodes"] = [{"metadata": {"name": "test-node", "labels": {"private": POISON}},
                     "status": {"nodeInfo": {"architecture": "amd64", "osImage": "Talos", "systemUUID": POISON},
                                "capacity": {"cpu": "8", "memory": "16Gi", "nvidia.com/gpu": "8"},
                                "allocatable": {"cpu": "7500m", "memory": "15Gi"},
                                "addresses": [{"type": "InternalIP", "address": "10.1.2.3"}],
                                "conditions": [{"type": "Ready", "status": "True", "message": POISON}]}}]
    raw["metrics"] = [{"metadata": {"name": "test-node"}, "timestamp": collector.iso(NOW - 20),
                       "usage": {"cpu": "500000000n", "memory": "2Gi"}}]
    raw["hardware"] = [{"metric": {"instance": "10.1.2.3:9100", "product_name": "Test server", "system_vendor": "Test", "product_serial": POISON}}]
    raw["deployments"] = [{"kind": "Deployment", "metadata": {"name": "new-service", "namespace": "new-namespace", "generation": 2, "annotations": {"private": POISON}},
                           "spec": {"replicas": 2, "template": {"spec": {"containers": [{"env": [{"value": POISON}], "image": POISON}]}}},
                           "status": {"observedGeneration": 2, "readyReplicas": 2, "availableReplicas": 2, "updatedReplicas": 2}}]
    raw["pods"] = [{"metadata": {"name": POISON}, "status": {"phase": "Running", "podIP": "10.1.2.9", "conditions": [{"type": "Ready", "status": "False"}]}}]
    return raw


class ProjectionTests(unittest.TestCase):
    def test_typed_api_lists_can_omit_item_kind(self):
        raw = fixture()
        del raw["deployments"][0]["kind"]
        raw["statefulsets"] = [copy.deepcopy(raw["deployments"][0])]
        raw["daemonsets"] = [copy.deepcopy(raw["deployments"][0])]
        raw["daemonsets"][0]["status"].update(desiredNumberScheduled=3, numberReady=3, numberAvailable=3, updatedNumberScheduled=3)
        services = collector.project(raw, NOW)["services"]
        self.assertEqual({s["kind"] for s in services}, {"Deployment", "StatefulSet", "DaemonSet"})
        self.assertTrue(all(s["status"] == "healthy" for s in services))

    def test_quantity_and_automatic_inventory(self):
        self.assertEqual(collector.quantity("2Gi"), 2 * 1024 ** 3)
        self.assertEqual(collector.quantity("7500m"), 7.5)
        self.assertEqual(collector.quantity("500000000n"), .5)
        self.assertEqual(collector.quantity("2e3"), 2000)
        feed = collector.project(fixture(), NOW)
        self.assertEqual(feed["services"][0]["id"], "new-namespace/deployment/new-service")
        self.assertEqual(feed["nodes"][0]["model"], "Test server")
        self.assertEqual(feed["summary"]["usage"]["cpuCores"], .5)
        self.assertEqual(feed["summary"]["readyPods"], 0)  # Running is not Ready.

    def test_private_fields_cannot_escape(self):
        serialized = json.dumps(collector.project(fixture(), NOW))
        for value in [POISON, "10.1.2.3", "10.1.2.9", "systemUUID", "product_serial", "annotations", "containers"]:
            self.assertNotIn(value, serialized)

    def test_rollout_generation_and_updated_replicas(self):
        raw = fixture()
        raw["deployments"][0]["status"]["observedGeneration"] = 1
        self.assertEqual(collector.project(raw, NOW)["cluster"]["status"], "unknown")
        raw["deployments"][0]["status"].update(observedGeneration=2, updatedReplicas=1)
        self.assertEqual(collector.project(raw, NOW)["cluster"]["status"], "degraded")
        raw["deployments"][0]["spec"]["replicas"] = 0
        self.assertEqual(collector.project(raw, NOW)["services"][0]["status"], "paused")

    def test_optional_failure_and_stale_metrics_are_not_zeros(self):
        raw = fixture()
        raw["storage"] = None
        raw["metrics"][0]["timestamp"] = collector.iso(NOW - 121)
        feed = collector.project(raw, NOW)
        self.assertTrue(feed["partial"])
        self.assertIsNone(feed["storage"])
        self.assertIn("storage", feed["unavailableSources"])
        self.assertIsNone(feed["nodes"][0]["usage"]["cpuCores"])
        self.assertIsNone(feed["summary"]["usage"]["memoryBytes"])

    def test_partial_node_coverage_does_not_understate_total(self):
        raw = fixture()
        extra = copy.deepcopy(raw["nodes"][0])
        extra["metadata"]["name"] = "second-node"
        raw["nodes"].append(extra)
        feed = collector.project(raw, NOW)
        self.assertEqual(feed["summary"]["usage"]["measuredNodes"], 1)
        self.assertIsNone(feed["summary"]["usage"]["cpuCores"])
        self.assertTrue(feed["partial"])

    def test_ephemeral_grouping_and_visibility(self):
        raw = fixture()
        for index in [1, 2]:
            obj = copy.deepcopy(raw["deployments"][0])
            obj["metadata"].update(namespace="coder", name=f"coder-00000000-0000-0000-0000-00000000000{index}")
            raw["deployments"].append(obj)
        hidden = copy.deepcopy(raw["deployments"][0])
        hidden["metadata"]["annotations"]["status.olympus.dev/visibility"] = "private"
        hidden["metadata"]["name"] = "hidden-service"
        raw["deployments"].append(hidden)
        feed = collector.project(raw, NOW)
        group = next(s for s in feed["services"] if s["kind"] == "Group")
        self.assertEqual(group["members"], 2)
        self.assertEqual(group["readyReplicas"], 4)
        self.assertNotIn("00000000", json.dumps(feed))
        self.assertNotIn("hidden-service", json.dumps(feed))

    def test_core_failure_retains_previous_snapshot(self):
        class FailedReader:
            def get(self, key):
                if key == "deployments":
                    raise OSError(POISON)
                return fixture().get(key, [])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            collector.write_snapshot(collector.project(fixture(), NOW), path)
            old = (path / "cluster.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "core discovery incomplete"):
                collector.write_snapshot(collector.collect(FailedReader()), path)
            self.assertEqual((path / "cluster.json").read_bytes(), old)

    def test_contract_and_additional_fields_rejected(self):
        from jsonschema import Draft202012Validator, FormatChecker
        schema = json.loads((Path(__file__).parent / "schema.json").read_text())
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        Draft202012Validator.check_schema(schema)
        feed = collector.project(fixture(), NOW)
        validator.validate(feed)
        feed["nodes"][0]["ip"] = POISON
        self.assertTrue(list(validator.iter_errors(feed)))


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)
        collector.write_snapshot(collector.project(fixture(), NOW), self.path)
        self.override = patch.object(server, "SNAPSHOT", self.path / "cluster.json")
        self.override.start()

    def tearDown(self):
        self.override.stop()
        self.directory.cleanup()

    def request(self, path=server.PREFIX + "/cluster", method="GET", now=NOW, **extra):
        response = {}
        def start(status, headers):
            response.update(code=int(status[:3]), headers=dict(headers))
        with patch.object(server.time, "time", return_value=now):
            body = b"".join(server.application({"PATH_INFO": path, "REQUEST_METHOD": method, **extra}, start))
        return response, body

    def test_read_only_fixed_routes_and_head(self):
        for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"]:
            response, body = self.request(method=method)
            self.assertEqual(response["code"], 405)
        for path in ["/api/v1/secrets", server.PREFIX + "/../../etc/passwd", server.PREFIX + "/proxy"]:
            self.assertEqual(self.request(path)[0]["code"], 404)
        self.assertEqual(self.request(method="HEAD")[1], b"")

    def test_fresh_stale_etag_and_startup(self):
        response, body = self.request()
        self.assertEqual(response["code"], 200)
        self.assertFalse(json.loads(body)["stale"])
        etag = response["headers"]["ETag"]
        self.assertEqual(self.request(HTTP_IF_NONE_MATCH=etag)[0]["code"], 304)
        response, body = self.request(now=NOW + 120, HTTP_IF_NONE_MATCH=etag)
        self.assertEqual(response["code"], 200)
        self.assertTrue(json.loads(body)["stale"])
        self.assertEqual(json.loads(body)["cluster"]["status"], "unknown")
        self.assertEqual(response["headers"]["Cache-Control"], "no-store")
        (self.path / "cluster.json").unlink()
        self.assertEqual(self.request()[0]["code"], 503)


if __name__ == "__main__":
    unittest.main()
