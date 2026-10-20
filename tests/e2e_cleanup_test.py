"""Startup-failure cleanup regressions; run on Linux and Windows Python."""
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from e2e import Device, NaradIntegration


class CleanupTests(unittest.TestCase):
    def device(self, root):
        device = Device.__new__(Device)
        device.state = root / 'Alice'
        device.name = 'Alice'
        device.control = 12345
        device.api = 12347
        device.discovery = False
        device.process = None
        return device

    def test_failed_spawn_closes_parent_log(self):
        with tempfile.TemporaryDirectory(prefix='narad-cleanup-') as folder:
            root = Path(folder)
            device = self.device(root)
            with patch('e2e.subprocess.Popen', side_effect=OSError('spawn failed fixture')):
                with self.assertRaisesRegex(OSError, 'spawn failed fixture'):
                    device.start()
            # Windows refuses this deletion if the parent left its log open.
            (root / 'Alice.log').unlink()
            device.stop()  # Repeated cleanup is safe.

    def test_child_startup_failure_is_reaped_and_reports_original_error(self):
        popen = subprocess.Popen
        with tempfile.TemporaryDirectory(prefix='narad-cleanup-') as folder:
            root = Path(folder)
            device = self.device(root)
            def failing_child(*args, **kwargs):
                return popen([sys.executable, '-u', '-c',
                    "import sys; print('startup failed fixture'); sys.exit(7)"], **kwargs)
            with patch('e2e.subprocess.Popen', side_effect=failing_child), \
                    patch.object(device, 'call', side_effect=OSError('not ready')):
                with self.assertRaisesRegex(RuntimeError, 'startup failed fixture'):
                    device.start()
            self.assertEqual(device.process.wait(timeout=3), 7)
            (root / 'Alice.log').unlink()
            device.stop()

    def test_readiness_timeout_stops_live_child_before_removing_log(self):
        popen = subprocess.Popen
        with tempfile.TemporaryDirectory(prefix='narad-cleanup-') as folder:
            root = Path(folder)
            device = self.device(root)
            def sleeping_child(*args, **kwargs):
                return popen([sys.executable, '-c', 'import time; time.sleep(60)'], **kwargs)
            # Do not patch the shared time module used by subprocess.wait().
            clock = SimpleNamespace(monotonic=Mock(side_effect=[0, 11]))
            with patch('e2e.subprocess.Popen', side_effect=sleeping_child), patch('e2e.time', clock):
                with self.assertRaisesRegex(RuntimeError, 'daemon startup timed out'):
                    device.start()
            self.assertIsNotNone(device.process.poll())
            (root / 'Alice.log').unlink()

    def test_partial_setup_stops_alice_before_removing_temporary_directory(self):
        alice = Mock()
        case = NaradIntegration('test_file_offer_above_one_gib_has_no_size_cap')
        result = unittest.TestResult()
        def stop():
            self.assertTrue(Path(case.tmp.name).exists())
        alice.stop.side_effect = stop
        with patch('e2e.Device', side_effect=[alice, RuntimeError('Bob startup failed fixture')]):
            case.run(result)
        self.assertEqual(len(result.errors), 1)
        self.assertIn('Bob startup failed fixture', result.errors[0][1])
        alice.stop.assert_called_once()
        self.assertFalse(Path(case.tmp.name).exists())

    def test_first_device_failure_still_removes_temporary_directory(self):
        case = NaradIntegration('test_file_offer_above_one_gib_has_no_size_cap')
        result = unittest.TestResult()
        with patch('e2e.Device', side_effect=RuntimeError('Alice startup failed fixture')):
            case.run(result)
        self.assertEqual(len(result.errors), 1)
        self.assertIn('Alice startup failed fixture', result.errors[0][1])
        self.assertFalse(Path(case.tmp.name).exists())


if __name__ == '__main__':
    unittest.main(defaultTest='CleanupTests', verbosity=2)
