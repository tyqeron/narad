"""Real two-daemon TLS integration tests. Run after cargo build --workspace."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parents[1] / "target/debug/narad"


def free_port_pair():
    for _ in range(100):
        with socket.socket() as first:
            first.bind(("127.0.0.1", 0))
            port = first.getsockname()[1]
            try:
                with socket.socket() as second:
                    second.bind(("127.0.0.1", port + 1))
                    return port
            except OSError:
                pass
    raise RuntimeError("no free ports")


class Device:
    def __init__(self, root, name):
        self.state = root / name
        self.control = free_port_pair()
        self.api = free_port_pair()
        self.name = name
        self.process = None
        self.start()

    def start(self):
        self.log = open(self.state.parent / f"{self.name}.log", "a")
        self.process = subprocess.Popen([
            str(BIN), "--state", str(self.state), "--api-port", str(self.api),
            "serve", "--name", self.name, "--port", str(self.control),
            "--address", "127.0.0.1", "--no-discovery",
        ], stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError((self.state.parent / f"{self.name}.log").read_text())
            try:
                self.call(op="status")
                return
            except (OSError, ValueError, RuntimeError):
                time.sleep(0.05)
        raise RuntimeError("daemon startup timed out")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            self.process.wait(timeout=10)
        self.log.close()

    def call(self, token=None, **command):
        token = token if token is not None else (self.state / "api-token").read_text()
        with socket.create_connection(("127.0.0.1", self.api), timeout=30) as s:
            s.settimeout(60)
            s.sendall(json.dumps({"token": token, "command": command}).encode() + b"\n")
            data = s.makefile("rb").readline(128 * 1024 + 2)
        result = json.loads(data)
        if not result.get("ok"):
            raise RuntimeError(result.get("error"))
        return result


class NaradIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="narad-e2e-")
        self.root = Path(self.tmp.name)
        self.a = Device(self.root, "Alice")
        self.b = Device(self.root, "Bob")
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.a.stop)
        self.addCleanup(self.b.stop)
        self.aid = self.a.call(op="status")["device"]["device_id"]
        self.bid = self.b.call(op="status")["device"]["device_id"]

    def pair(self):
        invite = self.b.call(op="invite")["invitation"]
        pair = self.a.call(op="pair", invitation=invite)
        with self.assertRaisesRegex(RuntimeError, "code mismatch"):
            self.b.call(op="pair_approve", id=pair["id"], code="wrong")
        with self.assertRaisesRegex(RuntimeError, "not approved"):
            self.a.call(op="pair_confirm", id=pair["id"], code=pair["code"])
        self.b.call(op="pair_approve", id=pair["id"], code=pair["code"])
        self.a.call(op="pair_confirm", id=pair["id"], code=pair["code"])

    def test_pairing_permissions_clipboard_revocation_and_restart(self):
        self.pair()
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="send_clipboard", peer_id=self.bid, text="hello")
        self.b.call(op="permission", peer_id=self.aid, capability="clipboard.sync", allow=True)
        offer = self.a.call(op="send_clipboard", peer_id=self.bid, text="hello local world")
        self.assertEqual(self.b.call(op="clipboard_accept", id=offer["id"])["text"], "hello local world")
        self.b.stop()
        self.b.start()
        self.assertEqual(self.b.call(op="status")["device"]["device_id"], self.bid)
        self.a.call(op="send_clipboard", peer_id=self.bid, text="after restart")
        self.b.call(op="permission", peer_id=self.aid, capability="clipboard.sync", allow=False)
        self.assertEqual(self.b.call(op="status")["clipboard"], [])
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="send_clipboard", peer_id=self.bid, text="blocked")
        self.b.call(op="unpair", peer_id=self.aid)
        with self.assertRaisesRegex(RuntimeError, "not paired"):
            self.a.call(op="ping_peer", peer_id=self.bid)

    def test_file_approval_restart_completion_and_cancellation(self):
        self.pair()
        source = self.root / "sample.bin"
        source.write_bytes(os.urandom(256 * 1024 + 9))
        offer = self.a.call(op="send_file", peer_id=self.bid, path=str(source))
        self.assertEqual(offer["status"], "pending")
        self.assertEqual(self.b.call(op="status")["transfers"][0]["received"], 0)
        self.b.call(op="file_accept", id=offer["id"])
        self.b.stop()
        self.b.start()
        result = self.a.call(op="send_file", peer_id=self.bid, path=str(source), id=offer["id"])
        self.assertEqual(result["status"], "completed")
        self.assertEqual(Path(result["path"]).read_bytes(), source.read_bytes())
        retry = self.a.call(op="send_file", peer_id=self.bid, path=str(source), id=offer["id"])
        self.assertEqual(retry["status"], "completed")
        cancelled = self.a.call(op="send_file", peer_id=self.bid, path=str(source))
        self.b.call(op="file_cancel", id=cancelled["id"])
        self.assertEqual(self.a.call(op="send_file", peer_id=self.bid, path=str(source), id=cancelled["id"])["status"], "cancelled")

    def test_bad_local_token_expired_invite_and_wrong_certificate_pin(self):
        with self.assertRaisesRegex(RuntimeError, "authentication failed"):
            self.a.call(op="status", token="wrong")
        invite = self.b.call(op="invite")["invitation"]
        invite["expires_at"] = 1
        with self.assertRaisesRegex(RuntimeError, "expired"):
            self.a.call(op="pair", invitation=invite)
        invite = self.b.call(op="invite")["invitation"]
        invite["peer"]["certificate_hash"] = "0" * 64
        with self.assertRaises(RuntimeError):
            self.a.call(op="pair", invitation=invite)
        self.assertFalse(self.a.call(op="status")["paired"])

    def test_media_signaling_gated_by_approval_and_stops_on_revocation(self):
        self.pair()
        self.a.call(op="media_ready", ready=True)
        self.b.call(op="media_ready", ready=True)
        offer = self.a.call(op="media_start", peer_id=self.bid)
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="media_send", peer_id=self.bid, id=offer["id"], data={"type": "offer", "sdp": "test"})
        self.b.call(op="media_accept", id=offer["id"])
        self.a.call(op="media_poll", peer_id=self.bid, id=offer["id"])
        self.a.call(op="media_send", peer_id=self.bid, id=offer["id"], data={"type": "offer", "sdp": "test"})
        self.assertEqual(len(self.b.call(op="media_events")["signals"]), 1)
        self.b.call(op="permission", peer_id=self.aid, capability="audio.output", allow=False)
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="media_send", peer_id=self.bid, id=offer["id"], data={"type": "candidate"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
