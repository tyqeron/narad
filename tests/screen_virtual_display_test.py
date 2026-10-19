"""Pure virtual-output selection tests; no desktop session or GUI dependencies."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('narad_virtual', Path(__file__).resolve().parents[1] / 'clients/flutter/assets/helpers/screen_virtual_display.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

class VirtualOutputTest(unittest.TestCase):
    def test_renumbered_physical_output_is_not_changed(self):
        before = [{'name': 'eDP-1', 'id': 1, 'connected': True}]
        current = [{'name': 'Virtual-narad', 'id': 1, 'connected': True, 'replicationSource': 2},
                   {'name': 'eDP-1', 'id': 2, 'connected': True}]
        self.assertEqual(helper.select_new_output(before,current)['name'],'Virtual-narad')

    def test_second_virtual_monitor_does_not_replace_the_first(self):
        before = [{'name':'Virtual-narad','connected':True,'replicationSource':0}]
        current = [dict(before[0],id=1), {'name':'Virtual-narad','id':2,'connected':True,'replicationSource':3}]
        self.assertEqual(helper.select_new_output(before,current)['id'],2)

    def test_unrelated_physical_connector_cannot_be_used_as_virtual(self):
        self.assertIsNone(helper.select_new_output([], [{'name':'HDMI-1','connected':True}]))

if __name__ == '__main__':
    unittest.main()
