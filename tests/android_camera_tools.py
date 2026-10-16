#!/usr/bin/env python3
"""Opt-in physical camera test: switch lenses, capture PNG and decode a temporary MP4.

Requires an unlocked Android tablet, approved camera access, Flutter and FFmpeg.
Only Narad's named temporary fixture is read; no personal files/contacts are read.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True, help='Use a direct ADB IP:port when mDNS names contain spaces')
    parser.add_argument('--background', action='store_true', help='Press Home during capture and verify background MP4')
    args = parser.parse_args()
    adb = [os.environ.get('ADB', 'adb'), '-s', args.serial, 'shell', 'run-as', 'dev.narad.narad_client']
    process = subprocess.Popen([os.environ.get('FLUTTER_BIN', 'flutter'), 'test',
        'integration_test/android_camera_test.dart', '--no-uninstall', '-d', args.serial,
        *(['--dart-define=NARAD_BACKGROUND_CAMERA=true'] if args.background else [])], cwd=ROOT / 'clients/flutter')
    checked = False
    backgrounded = False
    try:
        with tempfile.TemporaryDirectory(prefix='narad-tablet-video-') as temporary:
            video = Path(temporary) / 'fixture.mp4'
            deadline = time.monotonic() + 600
            while process.poll() is None and time.monotonic() < deadline:
                if args.background and not backgrounded:
                    ready = subprocess.run(adb + ['test', '-f', 'cache/narad-camera-background.ready'], capture_output=True)
                    if ready.returncode == 0:
                        subprocess.run([os.environ.get('ADB', 'adb'), '-s', args.serial, 'shell', 'input', 'keyevent', 'KEYCODE_HOME'], check=True)
                        subprocess.run(adb + ['touch', 'cache/narad-camera-background.active'], check=True)
                        backgrounded = True
                result = subprocess.run(adb + ['cat', 'cache/narad-camera-fixture.mp4'], capture_output=True)
                if not checked and result.returncode == 0 and len(result.stdout) > 1000:
                    video.write_bytes(result.stdout)
                    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(video)], capture_output=True, text=True)
                    if probe.returncode == 0:
                        streams = json.loads(probe.stdout)['streams']
                        pictures = [s for s in streams if s['codec_type'] == 'video']
                        assert pictures and not any(s['codec_type'] == 'audio' for s in streams)
                        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-f', 'null', '-'], check=True, capture_output=True)
                        if args.background:
                            assert backgrounded, 'Capture did not run in background'
                            assert float(pictures[0]['duration']) >= 5 and int(pictures[0]['nb_frames']) >= 30, 'Background camera frames stopped'
                            print('PASS sustained background camera:', pictures[0]['duration'], 'seconds,', pictures[0]['nb_frames'], 'frames', flush=True)
                            subprocess.run([os.environ.get('ADB', 'adb'), '-s', args.serial, 'shell', 'am', 'start', '-n', 'dev.narad.narad_client/.MainActivity'], check=True, capture_output=True)
                        subprocess.run(adb + ['touch', 'cache/narad-camera-fixture.checked'], check=True, capture_output=True)
                        print('PASS tablet MP4 fully decodes:', pictures[0]['codec_name'], pictures[0]['width'], pictures[0]['height'], 'video only', flush=True)
                        checked = True
                time.sleep(0.5)
            code = process.wait(timeout=10)
            assert code == 0 and checked, 'Camera integration/host decode did not pass'
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
        subprocess.run(adb + ['rm', '-f', 'cache/narad-camera-fixture.mp4', 'cache/narad-camera-fixture.checked', 'cache/narad-camera-background.ready', 'cache/narad-camera-background.active'], capture_output=True)


if __name__ == '__main__':
    main()
