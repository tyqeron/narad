"""Real two-daemon TLS integration tests. Run after cargo build --workspace."""
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

BIN = Path(os.environ.get("NARAD_TEST_BIN", str(Path(__file__).resolve().parents[1] / ("target/debug/narad.exe" if os.name == "nt" else "target/debug/narad"))))


def free_daemon_ports():
    """Choose distinct control/file/API ports while all three are reserved.

    In particular, Windows may immediately reuse a just-released ephemeral port.
    These reservations avoid self-collisions; the daemon binds them after return.
    """
    for _ in range(100):
        with socket.socket() as control, socket.socket() as files, socket.socket() as api:
            control.bind(("127.0.0.1", 0))
            port = control.getsockname()[1]
            if port == 65535:
                continue
            try:
                files.bind(("127.0.0.1", port + 1))
                api.bind(("127.0.0.1", 0))
                return port, api.getsockname()[1]
            except OSError:
                pass
    raise RuntimeError("no free daemon ports")


class Device:
    def __init__(self, root, name):
        self.state = root / name
        self.control, self.api = free_daemon_ports()
        self.name = name
        self.process = None
        self.discovery = False
        self.start()

    def start(self):
        if self.process and self.process.poll() is None:
            raise RuntimeError("daemon is already running")
        log_path = self.state.parent / f"{self.name}.log"
        try:
            # The child owns its inherited handle; the parent must close its copy
            # even if Popen or the readiness check fails (Windows locks open files).
            with log_path.open("a") as log:
                self.process = subprocess.Popen([
                    str(BIN), "--state", str(self.state), "--api-port", str(self.api),
                    "serve", "--name", self.name, "--port", str(self.control),
                    "--address", "127.0.0.1", *([] if self.discovery else ["--no-discovery"]),
                ], stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(log_path.read_text())
                try:
                    self.call(op="status")
                    return
                except (OSError, ValueError, RuntimeError):
                    time.sleep(0.05)
            raise RuntimeError("daemon startup timed out: " + log_path.read_text())
        except BaseException:
            self.stop()
            raise

    def stop(self):
        if self.process and self.process.poll() is None:
            if os.name == "nt":
                self.process.terminate()
            else:
                self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
                raise RuntimeError("daemon did not stop: " + (self.state.parent / f"{self.name}.log").read_text())

    def call(self, token=None, **command):
        token = token if token is not None else (self.state / "api-token").read_text()
        with socket.create_connection(("127.0.0.1", self.api), timeout=30) as s:
            s.settimeout(60)
            s.sendall(json.dumps({"token": token, "command": command}).encode() + b"\n")
            data = s.makefile("rb").readline(512 * 1024 + 2)
        result = json.loads(data)
        if not result.get("ok"):
            raise RuntimeError(result.get("error"))
        return result


class NaradIntegration(unittest.TestCase):
    def test_file_offer_above_one_gib_has_no_size_cap(self):
        self.pair()
        source = self.root / "large-file.bin"
        size = 1024 * 1024 * 1024 + 65537
        with source.open("wb") as output:
            output.truncate(size)  # Sparse fixture; no giant memory allocation.
        offered = self.a.call(op="send_file", peer_id=self.bid, path=str(source))
        self.assertEqual(offered["status"], "pending")
        incoming = next(t for t in self.b.call(op="status")["transfers"] if t["id"] == offered["id"])
        self.assertEqual(incoming["file_size"], size)
        self.b.call(op="file_cancel", id=offered["id"])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="narad-e2e-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.a = Device(self.root, "Alice")
        self.addCleanup(self.a.stop)
        self.b = Device(self.root, "Bob")
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

    def test_nearby_request_auto_connects_only_after_acceptance(self):
        peer = self.b.call(op="status")["device"]
        request = self.a.call(op="pair_nearby", peer=peer)
        self.assertFalse(self.a.call(op="status")["paired"])
        self.assertFalse(self.b.call(op="status")["paired"])
        incoming = self.b.call(op="status")["pairings"][0]
        self.assertTrue(incoming["nearby"])
        self.assertEqual(incoming["code"], request["code"])
        with self.assertRaisesRegex(RuntimeError, "already pending"):
            self.a.call(op="pair_nearby", peer=peer)
        self.b.call(op="pair_approve", id=request["id"], code=request["code"])
        # No invitation or sender-side pair_confirm call is used.
        deadline = time.monotonic() + 10
        while self.bid not in self.a.call(op="status")["paired"]:
            self.assertLess(time.monotonic(), deadline, "nearby request did not auto-connect")
            time.sleep(0.1)
        self.assertIn(self.aid, self.b.call(op="status")["paired"])
        self.a.call(op="ping_peer", peer_id=self.bid)
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="send_clipboard", peer_id=self.bid, text="still requires permission")
        self.a.stop()
        self.b.stop()
        self.a.start()
        self.b.start()
        self.a.call(op="ping_peer", peer_id=self.bid)

    def test_nearby_decline_and_sender_cancel_never_connect(self):
        peer = self.b.call(op="status")["device"]
        request = self.a.call(op="pair_nearby", peer=peer)
        self.b.call(op="pair_deny", id=request["id"])
        deadline = time.monotonic() + 10
        while next(p for p in self.a.call(op="status")["pairings"] if p["id"] == request["id"])["status"] != "denied":
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)
        self.assertFalse(self.a.call(op="status")["paired"])
        self.assertFalse(self.b.call(op="status")["paired"])
        request = self.a.call(op="pair_nearby", peer=peer)
        self.a.call(op="pair_deny", id=request["id"])
        with self.assertRaisesRegex(RuntimeError, "not awaiting approval"):
            self.b.call(op="pair_approve", id=request["id"], code=request["code"])
        time.sleep(2.2)
        self.assertFalse(self.a.call(op="status")["paired"])
        self.assertFalse(self.b.call(op="status")["paired"])

    def wait_for(self, predicate, message, timeout=15):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.assertLess(time.monotonic(), deadline, message)
            time.sleep(0.1)

    def test_authenticated_presence_detects_offline_and_reconnect(self):
        self.pair()
        self.wait_for(lambda: self.a.call(op="status")["presence"].get(self.bid, {}).get("online"), "peer not online")
        self.b.stop()
        self.wait_for(lambda: not self.a.call(op="status")["presence"][self.bid]["online"], "peer not offline")
        self.assertIsNotNone(self.a.call(op="status")["presence"][self.bid]["last_seen"])
        self.b.start()
        self.wait_for(lambda: self.a.call(op="status")["presence"][self.bid]["online"], "peer not online after restart")

    def test_persistent_grants_remove_file_clipboard_and_media_prompts(self):
        self.pair()
        source = self.root / "automatic.bin"
        source.write_bytes(os.urandom(128 * 1024 + 7))
        self.b.call(op="permission", peer_id=self.aid, capability="file.transfer", allow=True)
        sent = self.a.call(op="send_file", peer_id=self.bid, path=str(source))
        self.assertEqual(sent["status"], "completed")
        self.assertEqual(Path(sent["path"]).read_bytes(), source.read_bytes())
        self.b.stop()
        self.b.start()
        self.assertEqual(self.a.call(op="send_file", peer_id=self.bid, path=str(source))["status"], "completed")
        self.b.call(op="permission", peer_id=self.aid, capability="clipboard.sync", allow=True)
        self.a.call(op="send_clipboard", peer_id=self.bid, text="automatic clipboard fixture")
        self.assertEqual(self.b.call(op="status")["clipboard"][0]["status"], "automatic")
        self.assertEqual(self.b.call(op="platform_events")["clipboard"][0]["text"], "automatic clipboard fixture")
        self.assertEqual(self.b.call(op="platform_events")["clipboard"], [])
        self.a.call(op="media_ready", ready=True, audio_ready=True, camera_ready=True)
        self.b.call(op="media_ready", ready=True, audio_ready=True, camera_ready=True)
        for capability, kind in [("audio.output", "audio"), ("camera.stream", "camera")]:
            self.b.call(op="permission", peer_id=self.aid, capability=capability, allow=True)
            offer = self.a.call(op="media_start", peer_id=self.bid, kind=kind)
            response = self.a.call(op="media_poll", peer_id=self.bid, id=offer["id"])
            self.assertEqual(response["session"]["state"], "authorized")
            self.assertEqual(response["session"]["capability"], capability)
        self.b.call(op="permission", peer_id=self.aid, capability="file.transfer", allow=False)
        with self.assertRaisesRegex(RuntimeError,"permission denied"):
            self.a.call(op="send_file", peer_id=self.bid, path=str(source))

    def test_shared_folder_is_scoped_and_downloads_without_prompts(self):
        self.pair()
        shared = self.b.state / "shared"
        shared.mkdir()
        (shared / "hello.txt").write_bytes(b"shared fixture")
        (shared / "escape").symlink_to(self.b.state / "api-token")
        with self.assertRaisesRegex(RuntimeError,"permission denied"):
            self.a.call(op="browse_peer", peer_id=self.bid, path="")
        self.b.call(op="permission", peer_id=self.aid, capability="file.browse", allow=True)
        self.b.call(op="share_access", id="default", peer_id=self.aid, allow=True)
        files = self.a.call(op="browse_peer", peer_id=self.bid, path="")["entries"]
        self.assertEqual([f["name"] for f in files], ["hello.txt"])
        for path in ["../api-token", "escape", "/etc/passwd"]:
            with self.assertRaises(RuntimeError):
                self.a.call(op="read_shared", peer_id=self.bid, path=path, offset=0)
        result = self.a.call(op="download_shared", peer_id=self.bid, path="hello.txt")
        self.assertEqual(Path(result["path"]).read_bytes(), b"shared fixture")
        self.b.call(op="permission", peer_id=self.aid, capability="file.browse", allow=False)
        with self.assertRaisesRegex(RuntimeError,"permission denied"):
            self.a.call(op="browse_peer", peer_id=self.bid, path="")

    def test_selected_folder_upload_download_and_revocation(self):
        self.pair()
        selected = self.root / "selected"
        selected.mkdir()
        source = self.root / "generated.bin"
        source.write_bytes(bytes(range(256)) * 1025)
        folder = self.b.call(op="share_add", path=str(selected), label="Exchange", peer_id=self.aid)["id"]
        mount = "@" + folder
        self.b.call(op="permission", peer_id=self.aid, capability="file.browse", allow=True)
        listing = self.a.call(op="browse_peer", peer_id=self.bid, path="")
        self.assertTrue(any(e["path"] == mount and e["name"] == "Exchange" for e in listing["entries"]))
        with self.assertRaises(RuntimeError):
            self.a.call(op="upload_shared", peer_id=self.bid, path=mount, source=str(source))
        self.b.call(op="share_uploads", id=folder, enabled=True)
        self.b.call(op="permission", peer_id=self.aid, capability="file.upload", allow=True)
        self.a.call(op="upload_shared", peer_id=self.bid, path=mount, source=str(source))
        self.assertEqual((selected / source.name).read_bytes(), source.read_bytes())
        with self.assertRaises(RuntimeError):
            self.a.call(op="upload_shared", peer_id=self.bid, path=mount, source=str(source))
        downloaded = self.a.call(op="download_shared", peer_id=self.bid, path=mount + "/" + source.name)
        self.assertEqual(Path(downloaded["path"]).read_bytes(), source.read_bytes())
        self.b.call(op="share_access", id=folder, peer_id=self.aid, allow=False)
        self.assertFalse(self.a.call(op="browse_peer", peer_id=self.bid, path="")["entries"])
        with self.assertRaises(RuntimeError):
            self.a.call(op="read_shared", peer_id=self.bid, path=mount + "/" + source.name, offset=0)
        with self.assertRaises(RuntimeError):
            self.a.call(op="upload_shared", peer_id=self.bid, path=mount, source=str(source))
        existing=self.b.call(op="share_add", path=str(selected), label="Exchange", peer_id=self.aid)["id"]
        self.assertEqual(existing,folder)
        self.b.stop()
        self.b.start()
        self.assertEqual(self.b.call(op="status")["shared_folders"][0]["id"], folder)
        self.b.call(op="share_remove", id=folder)
        with self.assertRaises(RuntimeError):
            self.a.call(op="browse_peer", peer_id=self.bid, path=mount)
        self.assertEqual((selected / source.name).read_bytes(), source.read_bytes())

    def test_only_configured_command_presets_execute_and_revocation_stops_them(self):
        self.pair()
        with self.assertRaisesRegex(RuntimeError,"permission denied"):
            self.a.call(op="list_commands", peer_id=self.bid)
        preset = self.b.call(op="command_set", label="Fixture", script="printf narad-command-fixture")
        self.b.call(op="permission", peer_id=self.aid, capability="command.run", allow=True)
        commands = self.a.call(op="list_commands", peer_id=self.bid)["commands"]
        self.assertEqual(commands, [{"id":preset["id"], "label":"Fixture"}])
        result = self.a.call(op="run_command", peer_id=self.bid, id=preset["id"])
        self.assertEqual(result["stdout"], "narad-command-fixture")
        self.assertEqual(result["exit_code"], 0)
        with self.assertRaisesRegex(RuntimeError,"unknown command"):
            self.a.call(op="run_command", peer_id=self.bid, id="printf not-configured")
        waiting = self.b.call(op="command_set", label="Wait", script="sleep 30")
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            running = pool.submit(self.a.call, op="run_command", peer_id=self.bid, id=waiting["id"])
            time.sleep(0.5)
            self.b.call(op="permission", peer_id=self.aid, capability="command.run", allow=False)
            with self.assertRaisesRegex(RuntimeError,"revoked"):
                running.result(timeout=5)
        self.b.stop()
        self.b.start()
        self.assertEqual(len(self.b.call(op="status")["commands"]),2)
        for kind in ["lock", "unlock"]:
            with self.assertRaisesRegex(RuntimeError,"permission denied"):
                self.a.call(op="device_action",peer_id=self.bid,kind=kind)

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

    def test_interrupted_transfer_resumes_from_verified_checkpoint(self):
        self.pair()
        source = self.root / "interrupted.bin"
        source.write_bytes(os.urandom(8 * 1024 * 1024))
        offer = self.a.call(op="send_file", peer_id=self.bid, path=str(source))
        self.b.call(op="file_accept", id=offer["id"])
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            sending = pool.submit(self.a.call, op="send_file", peer_id=self.bid, path=str(source), id=offer["id"])
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                progress = self.b.call(op="status")["transfers"][0]["received"]
                if 0 < progress < source.stat().st_size:
                    break
                time.sleep(0.01)
            else:
                self.fail("failed to observe an interrupted checkpoint")
            self.b.stop()
            with self.assertRaises((RuntimeError, OSError)):
                sending.result(timeout=20)
        self.b.start()
        checkpoint = self.b.call(op="status")["transfers"][0]["received"]
        self.assertGreater(checkpoint, 0)
        self.assertLess(checkpoint, source.stat().st_size)
        self.a.stop()
        self.a.start()
        self.assertEqual(self.a.call(op="status")["outbound"][0]["id"], offer["id"])
        result = self.a.call(op="send_file", peer_id=self.bid, path=str(source), id=offer["id"])
        self.assertEqual(Path(result["path"]).read_bytes(), source.read_bytes())

    def test_file_revocation_survives_restart_and_needs_explicit_resume(self):
        self.pair()
        source = self.root / "private.txt"
        source.write_text("permission sensitive")
        offer = self.a.call(op="send_file", peer_id=self.bid, path=str(source))
        self.b.call(op="file_accept", id=offer["id"])
        self.b.call(op="permission", peer_id=self.aid, capability="file.transfer", allow=False)
        self.b.stop()
        self.b.start()
        self.b.call(op="permission", peer_id=self.aid, capability="file.transfer", allow=True)
        with self.assertRaisesRegex(RuntimeError, "unknown session"):
            self.a.call(op="send_file", peer_id=self.bid, path=str(source), id=offer["id"])
        self.b.call(op="file_resume", id=offer["id"])
        result = self.a.call(op="send_file", peer_id=self.bid, path=str(source), id=offer["id"])
        self.assertEqual(result["status"], "completed")

    @unittest.skipUnless(os.environ.get("NARAD_TEST_MDNS") == "1", "multicast test is opt-in")
    def test_mdns_discovery_is_untrusted_and_advertises_live_audio(self):
        self.a.stop()
        self.b.stop()
        self.a.discovery = self.b.discovery = True
        self.a.start()
        self.b.start()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            discovered = self.a.call(op="status")["discovered"]
            if any(p["device_id"] == self.bid for p in discovered):
                break
            time.sleep(0.1)
        else:
            self.fail("mDNS peer not discovered")
        self.assertFalse(self.a.call(op="status")["paired"])
        self.b.call(op="media_ready", ready=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            discovered = self.a.call(op="status")["discovered"]
            if any(p["device_id"] == self.bid and "audio.output" in p["capabilities"] for p in discovered):
                break
            time.sleep(0.1)
        else:
            self.fail("live audio capability not advertised")
        peer = next(p for p in discovered if p["device_id"] == self.bid)
        request = self.a.call(op="pair_nearby", peer=peer)
        self.b.call(op="pair_approve", id=request["id"], code=request["code"])
        deadline = time.monotonic() + 10
        while self.bid not in self.a.call(op="status")["paired"]:
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)

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

    def test_phone_bridge_grants_dispatch_results_and_revocation(self):
        self.pair()
        self.b.call(op="phone_bridge_ready", support={"enabled": True, "platform": "android"})
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="phone_request", peer_id=self.bid, kind="notifications", args={})
        self.b.call(op="permission", peer_id=self.aid, capability="notification.read", allow=True)
        with concurrent.futures.ThreadPoolExecutor() as executor:
            pending = executor.submit(self.a.call, op="phone_request", peer_id=self.bid, kind="notifications", args={})
            deadline = time.monotonic()+5
            while True:
                jobs = self.b.call(op="phone_jobs")["jobs"]
                if jobs: break
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            job = jobs[0]
            self.assertEqual(job["kind"], "notifications")
            self.assertEqual(self.b.call(op="phone_jobs")["jobs"], [])
            self.b.call(op="phone_validate", id=job["id"])
            self.b.call(op="phone_result", id=job["id"], result={"ok": True, "items": [{"title": "generated-private-fixture"}]})
            self.assertEqual(pending.result()["items"][0]["title"], "generated-private-fixture")
            self.assertNotIn("generated-private-fixture", json.dumps(self.b.call(op="status")))
            with self.assertRaises(RuntimeError):
                self.b.call(op="phone_result", id=job["id"], result={"ok": True})
            pending = executor.submit(self.a.call, op="phone_request", peer_id=self.bid, kind="notifications", args={})
            deadline = time.monotonic()+5
            while True:
                jobs = self.b.call(op="phone_jobs")["jobs"]
                if jobs: break
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            self.b.call(op="permission", peer_id=self.aid, capability="notification.read", allow=False)
            with self.assertRaisesRegex(RuntimeError, "permission denied"):
                self.b.call(op="phone_validate", id=jobs[0]["id"])
            with self.assertRaisesRegex(RuntimeError, "permission denied"):
                pending.result()

    def test_phone_bridge_is_opt_in_and_sms_send_has_separate_permission(self):
        self.pair()
        with self.assertRaisesRegex(RuntimeError, "unavailable"):
            self.a.call(op="phone_request", peer_id=self.bid, kind="support", args={})
        self.b.call(op="phone_bridge_ready", support={"enabled": True, "platform": "android"})
        self.b.call(op="permission", peer_id=self.aid, capability="sms.read", allow=True)
        for kind in ("sms_send", "dial", "notification_reply", "notification_dismiss"):
            with self.subTest(kind=kind), self.assertRaisesRegex(RuntimeError, "permission denied"):
                self.a.call(op="phone_request", peer_id=self.bid, kind=kind, args={})
        with self.assertRaisesRegex(RuntimeError, "unsupported phone action"):
            self.a.call(op="phone_request", peer_id=self.bid, kind="arbitrary_intent", args={})
        self.b.call(op="phone_bridge_ready", support={"enabled": False})
        with self.assertRaisesRegex(RuntimeError, "unavailable"):
            self.a.call(op="phone_request", peer_id=self.bid, kind="support", args={})

    def test_contacts_are_separately_granted_ephemeral_and_revocable(self):
        self.pair()
        self.b.call(op="phone_bridge_ready", support={"enabled": True, "contacts": True})
        self.b.call(op="permission", peer_id=self.aid, capability="sms.read", allow=True)
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="phone_request", peer_id=self.bid, kind="contacts_list", args={})
        self.b.call(op="permission", peer_id=self.aid, capability="contacts.read", allow=True)
        with concurrent.futures.ThreadPoolExecutor() as executor:
            pending = executor.submit(self.a.call, op="phone_request", peer_id=self.bid, kind="contacts_list", args={"after": "20"})
            deadline = time.monotonic()+5
            while True:
                jobs = self.b.call(op="phone_jobs")["jobs"]
                if jobs: break
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            self.assertEqual(jobs[0]["args"], {"after": "20"})
            self.b.call(op="phone_validate", id=jobs[0]["id"])
            self.b.call(op="phone_result", id=jobs[0]["id"], result={"ok": True, "items": [{"name": "Generated-private-contact", "phones": ["12345"]}], "next_after": "40"})
            self.assertEqual(pending.result()["next_after"], "40")
            self.assertNotIn("Generated-private-contact", json.dumps(self.b.call(op="status")))
        self.b.call(op="permission", peer_id=self.aid, capability="contacts.read", allow=False)
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="phone_request", peer_id=self.bid, kind="contacts_list", args={})

    def test_camera_signaling_uses_camera_permission_without_audio_grant(self):
        self.pair()
        for device in (self.a, self.b):
            device.call(op="media_ready", ready=True, audio_ready=False, camera_ready=True)
        offer = self.a.call(op="media_start", peer_id=self.bid, kind="camera")
        session = offer["id"]
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="media_send", peer_id=self.bid, id=session, data={"type": "offer", "sdp": "camera-test"})
        self.b.call(op="media_accept", id=session)
        self.a.call(op="media_poll", peer_id=self.bid, id=session)
        # Denied audio must never prevent an authorized camera session.
        self.a.call(op="permission", peer_id=self.bid, capability="audio.output", allow=False)
        self.b.call(op="permission", peer_id=self.aid, capability="audio.output", allow=False)
        for sender, receiver, peer_id, data in (
            (self.a, self.b, self.bid, {"type": "offer", "sdp": "camera-test"}),
            (self.b, self.a, self.aid, {"type": "answer", "sdp": "camera-test"}),
            (self.a, self.b, self.bid, {"type": "candidate", "candidate": "camera-test"}),
            (self.b, self.a, self.aid, {"type": "candidate", "candidate": "camera-test"}),
        ):
            sender.call(op="media_send", peer_id=peer_id, id=session, data=data)
            signals = receiver.call(op="media_events")["signals"]
            self.assertEqual(len(signals), 1)
            self.assertEqual(signals[0]["data"], data)
        self.b.call(op="permission", peer_id=self.aid, capability="camera.stream", allow=False)
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.a.call(op="media_send", peer_id=self.bid, id=session, data={"type": "candidate"})
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.b.call(op="media_send", peer_id=self.aid, id=session, data={"type": "candidate"})

    def test_camera_audio_needs_both_grants_and_stops_with_microphone(self):
        self.pair()
        self.a.call(op="media_ready", audio_ready=True, camera_ready=False, microphone_ready=False)
        self.b.call(op="media_ready", audio_ready=True, camera_ready=True, microphone_ready=True)
        self.b.call(op="permission", peer_id=self.aid, capability="camera.stream", allow=True)
        with self.assertRaisesRegex(RuntimeError, "microphone permission"):
            self.a.call(op="media_start", peer_id=self.bid, kind="camera", with_audio=True)
        self.b.call(op="permission", peer_id=self.aid, capability="audio.input", allow=True)
        session = self.a.call(op="media_start", peer_id=self.bid, kind="camera", with_audio=True)["id"]
        status = self.a.call(op="media_poll", peer_id=self.bid, id=session)["session"]
        self.assertTrue(status["with_audio"])
        self.assertEqual(status["state"], "authorized")
        self.a.call(op="media_send", peer_id=self.bid, id=session, data={"type":"offer","sdp":"fixture"})
        self.b.call(op="media_send", peer_id=self.aid, id=session, data={"type":"answer","sdp":"fixture"})
        self.b.call(op="media_ready", audio_ready=True, camera_ready=True, microphone_ready=False)
        self.assertEqual(self.a.call(op="media_poll", peer_id=self.bid, id=session)["session"]["state"], "closed")

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
