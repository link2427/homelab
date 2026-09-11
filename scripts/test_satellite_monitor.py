import datetime as dt
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('monitor',Path(__file__).with_name('check-satellite-data.py'))
monitor=importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def test_stale_data_and_missing_heartbeat_are_independent(self):
        now=dt.datetime(2026,9,11,tzinfo=dt.timezone.utc)
        at=lambda h:(now-dt.timedelta(hours=h)).isoformat()
        p={'lastPublished':at(37),'satellitesUpdatedAt':at(37),'lastChecked':at(1),'state':'published'}
        self.assertEqual(['publisher_heartbeat_missing','catalog_stale_critical'],monitor.evaluate({'live':True,'checkedAt':at(0),'publication':p},now))
        p.update(lastPublished=at(1),satellitesUpdatedAt=at(1),lastChecked=at(0),state='failed',failureCode='celestrak_timeout',retryNotBefore=at(1))
        self.assertEqual(['update_failed','retry_overdue'],monitor.evaluate({'live':True,'checkedAt':at(0),'publication':p},now))

    def test_unacknowledged_event_repeats_until_delivered_then_recovers_once(self):
        failure=monitor.transition({}, {'problems':['update_failed']})
        self.assertEqual('failure',failure['event']['type'])
        self.assertIn('event',monitor.transition(failure,{'problems':['update_failed']}))
        failure['acknowledgedSignature']=failure['signature']
        self.assertNotIn('event',monitor.transition(failure,{'problems':['update_failed']}))
        recovered=monitor.transition(failure,{'problems':[]})
        self.assertEqual('recovery',recovered['event']['type'])
        recovered['acknowledgedSignature']='healthy'
        self.assertNotIn('event',monitor.transition(recovered,{'problems':[]}))

    def test_monitor_never_targets_upstream_provider(self):
        self.assertNotIn('celestrak',monitor.STATUS_URL.lower())
        self.assertNotIn('celestrak',monitor.PUBLISHER_URL.lower())


if __name__=='__main__': unittest.main()
