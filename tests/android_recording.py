#!/usr/bin/env python3
"""Validate Android AAC/MP4 muxing using generated color video and a sine wave."""
import argparse
import array
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    adb = [os.environ.get('ADB', 'adb'), '-s', args.serial, 'shell', 'run-as', 'dev.narad.narad_client']
    process = subprocess.Popen([os.environ.get('FLUTTER_BIN', 'flutter'), 'test', 'integration_test/android_recording_test.dart', '--no-uninstall', '-d', args.serial], cwd=root / 'clients/flutter')
    checked = False
    try:
        with tempfile.TemporaryDirectory(prefix='narad-av-test-') as temporary:
            deadline = time.monotonic() + 600
            while process.poll() is None and time.monotonic() < deadline:
                result = subprocess.run(adb + ['cat', 'cache/narad-av-fixture.mp4'], capture_output=True)
                if not checked and result.returncode == 0 and len(result.stdout) > 1000:
                    path = Path(temporary) / 'fixture.mp4'
                    path.write_bytes(result.stdout)
                    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(path)], capture_output=True, text=True, check=True)
                    streams = json.loads(probe.stdout)['streams']
                    assert sorted(s['codec_type'] for s in streams) == ['audio', 'video']
                    assert next(s for s in streams if s['codec_type'] == 'audio')['codec_name'] == 'aac'
                    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'null', '-'], capture_output=True, check=True)
                    pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-vn', '-f', 's16le', '-'], capture_output=True, check=True).stdout
                    samples = array.array('h', pcm)
                    assert max(abs(v) for v in samples) > 3000, 'Recorded audio must contain generated tone'
                    subprocess.run(adb + ['touch', 'cache/narad-av-fixture.checked'], check=True)
                    checked = True
                    print('PASS Android MP4: video and AAC audio decode; generated tone verified', flush=True)
                time.sleep(0.5)
            assert process.wait(timeout=10) == 0 and checked, 'Android generated recording test failed'
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
        subprocess.run(adb + ['rm', '-f', 'cache/narad-av-fixture.mp4', 'cache/narad-av-fixture.checked'], capture_output=True)


if __name__ == '__main__':
    main()
