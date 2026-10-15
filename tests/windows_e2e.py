"""Windows-native daemon regression suite. Only generated fixtures; no media/lock capture."""
import concurrent.futures
import os
import time
import unittest
from pathlib import Path

from e2e import NaradIntegration


class WindowsIntegration(NaradIntegration):
    def test_shared_folder_is_scoped_and_downloads_without_prompts(self):
        self.pair()
        shared = self.b.state / 'shared'
        shared.mkdir(exist_ok=True)
        (shared / 'hello.txt').write_bytes(b'Windows shared fixture')
        with self.assertRaisesRegex(RuntimeError, 'permission denied'):
            self.a.call(op='browse_peer', peer_id=self.bid, path='')
        self.b.call(op='permission', peer_id=self.aid, capability='file.browse', allow=True)
        for path in ['../api-token', 'hello.txt:stream', 'CON', '/api-token', 'C:/Windows']:
            with self.assertRaises(RuntimeError):
                self.a.call(op='read_shared', peer_id=self.bid, path=path, offset=0)
        result = self.a.call(op='download_shared', peer_id=self.bid, path='hello.txt')
        self.assertEqual(Path(result['path']).read_bytes(), b'Windows shared fixture')
        self.b.call(op='permission', peer_id=self.aid, capability='file.browse', allow=False)
        with self.assertRaisesRegex(RuntimeError, 'permission denied'):
            self.a.call(op='browse_peer', peer_id=self.bid, path='')

    def test_only_configured_command_presets_execute_and_revocation_stops_them(self):
        self.pair()
        with self.assertRaisesRegex(RuntimeError, 'permission denied'):
            self.a.call(op='list_commands', peer_id=self.bid)
        preset = self.b.call(op='command_set', label='Fixture', script='echo narad-windows-fixture')
        self.b.call(op='permission', peer_id=self.aid, capability='command.run', allow=True)
        self.assertEqual(self.a.call(op='list_commands', peer_id=self.bid)['commands'], [{'id': preset['id'], 'label': 'Fixture'}])
        result = self.a.call(op='run_command', peer_id=self.bid, id=preset['id'])
        self.assertEqual(result['stdout'].strip(), 'narad-windows-fixture')
        self.assertEqual(result['exit_code'], 0)
        with self.assertRaisesRegex(RuntimeError, 'unknown command'):
            self.a.call(op='run_command', peer_id=self.bid, id='echo arbitrary-command')
        # Child processes inherit the command Job and must stop on revocation.
        waiting = self.b.call(op='command_set', label='Wait', script='ping -n 30 127.0.0.1 > nul')
        with concurrent.futures.ThreadPoolExecutor() as pool:
            running = pool.submit(self.a.call, op='run_command', peer_id=self.bid, id=waiting['id'])
            time.sleep(0.7)
            start = time.monotonic()
            self.b.call(op='permission', peer_id=self.aid, capability='command.run', allow=False)
            with self.assertRaisesRegex(RuntimeError, 'revoked'):
                running.result(timeout=5)
            self.assertLess(time.monotonic() - start, 5)

    def test_windows_identity_is_wrapped_and_restart_preserves_account_trust(self):
        self.pair()
        self.assertTrue((self.a.state / 'identity.dpapi').is_file())
        self.assertFalse((self.a.state / 'identity.json').exists())
        self.a.stop()
        self.a.start()
        self.assertEqual(self.a.call(op='status')['device']['device_id'], self.aid)
        self.assertIn(self.bid, self.a.call(op='status')['paired'])

    def test_windows_never_advertises_credential_bypass(self):
        status = self.a.call(op='status')
        self.assertEqual(status['device']['platform'], 'windows')
        self.assertNotIn('device.unlock', status['device']['capabilities'])
        self.pair()
        # The lock path stays ungranted: automated tests never lock the CI/user PC.
        with self.assertRaisesRegex(RuntimeError, 'permission denied'):
            self.a.call(op='device_action', peer_id=self.bid, kind='lock')


if __name__ == '__main__':
    if os.name != 'nt':
        raise SystemExit('Run this suite with Windows Python and a Windows narad.exe build.')
    # Do not also discover the imported base TestCase as a separate suite.
    unittest.main(defaultTest='WindowsIntegration', verbosity=2)
