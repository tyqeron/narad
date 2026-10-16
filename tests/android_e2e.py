#!/usr/bin/env python3
"""Opt-in physical Android/Linux interoperability check using this app's debug API.

Install/launch the debug APK first. No personal files, clipboard or microphone are
accessed. Only generated fixtures and a temporary test pairing are used.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

from e2e import BIN, free_port_pair

PACKAGE = 'dev.narad.narad_client'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True, help='adb device serial')
    parser.add_argument('--pairing', choices=['invitation', 'nearby'], default='invitation')
    parser.add_argument('--controls', action='store_true', help='Also test persistent grants, shared files and command presets')
    parser.add_argument('--widget', action='store_true', help='Test the debug-only real widget host and connected notification')
    args = parser.parse_args()
    adb = ['adb', '-s', args.serial]

    def run(*command, **kwargs):
        return subprocess.check_output(adb + list(command), **kwargs)

    # Read only our application's private local API token; never print it.
    for _ in range(100):
        candidate = subprocess.run(adb + ['shell', 'run-as', PACKAGE, 'cat', 'no_backup/narad/api-token'], capture_output=True)
        if candidate.returncode == 0:
            token = candidate.stdout.decode()
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('Install and launch the normal debug APK before running this harness')
    app_root = run('shell', 'run-as', PACKAGE, 'pwd').decode().strip()
    forward = int(run('forward', 'tcp:0', 'tcp:45700').decode().strip())

    def call(port, secret, **command):
        with socket.create_connection(('127.0.0.1', port), timeout=10) as connection:
            connection.settimeout(90)
            connection.sendall(json.dumps({'token': secret, 'command': command}).encode() + b'\n')
            line = connection.makefile('rb').readline(512 * 1024 + 2)
            if not line:
                raise ConnectionError('Android backend is not ready')
            result = json.loads(line)
        if not result.get('ok'):
            raise RuntimeError(result.get('error', 'API failed'))
        return result

    def phone(**command):
        return call(forward, token, **command)

    cleanup = []
    process = None
    try:
        for _ in range(100):
            candidate = subprocess.run(adb + ['shell', 'run-as', PACKAGE, 'cat', 'no_backup/narad/api-token'], capture_output=True)
            if candidate.returncode == 0:
                token = candidate.stdout.decode()
            try:
                status = phone(op='status')
                break
            except (OSError, RuntimeError):
                time.sleep(0.1)
        else:
            raise RuntimeError('The Android backend is not accepting local connections')
        assert status['device']['platform'] == 'android', status['device']['platform']
        phone_id = status['device']['device_id']
        address = status['device']['address']
        if address.startswith('127.'):
            raise RuntimeError('Connect Android to the same Wi-Fi/LAN as this computer and reopen Narad')
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
            route.connect((address, 45678))
            host_ip = route.getsockname()[0]
        with tempfile.TemporaryDirectory(prefix='narad-android-e2e-') as temporary:
            root = Path(temporary)
            state = root / 'desktop'
            api = free_port_pair()
            control = free_port_pair()
            with (root / 'desktop.log').open('w') as log:
                process = subprocess.Popen([
                    str(BIN), '--state', str(state), '--api-port', str(api),
                    'serve', '--name', 'Narad Android test', '--address', host_ip,
                    '--port', str(control), *([] if args.pairing == 'nearby' else ['--no-discovery']),
                ], stdout=log, stderr=log)
                for _ in range(200):
                    if process.poll() is not None:
                        raise RuntimeError((root / 'desktop.log').read_text())
                    if (state / 'api-token').exists():
                        try:
                            call(api, (state / 'api-token').read_text(), op='status')
                            break
                        except OSError:
                            pass
                    time.sleep(0.05)
                else:
                    raise RuntimeError('Desktop startup timed out')
                desktop_token = (state / 'api-token').read_text()

                def desktop(**command):
                    return call(api, desktop_token, **command)

                host_id = desktop(op='status')['device']['device_id']
                if args.pairing == 'nearby':
                    deadline = time.monotonic() + 25
                    while True:
                        discovered_phone = next((p for p in desktop(op='status')['discovered'] if p['device_id'] == phone_id), None)
                        discovered_host = next((p for p in phone(op='status')['discovered'] if p['device_id'] == host_id), None)
                        if discovered_phone and discovered_host:
                            break
                        if time.monotonic() > deadline:
                            raise RuntimeError(f'LAN mDNS discovery incomplete (desktop sees Android: {bool(discovered_phone)}, Android sees desktop: {bool(discovered_host)})')
                        time.sleep(0.2)
                    print('PASS Android and desktop discover each other over physical LAN mDNS')
                    pair = desktop(op='pair_nearby', peer=discovered_phone)
                else:
                    pair = desktop(op='pair', invitation=phone(op='invite')['invitation'])
                phone(op='pair_approve', id=pair['id'], code=pair['code'])
                cleanup.append(lambda: phone(op='unpair', peer_id=host_id))
                if args.pairing == 'nearby':
                    deadline = time.monotonic() + 15
                    while phone_id not in desktop(op='status')['paired']:
                        if time.monotonic() > deadline:
                            raise RuntimeError('Nearby pairing did not complete automatically')
                        time.sleep(0.1)
                    print('PASS Desktop nearby request connects after Android acceptance without invitation')
                else:
                    desktop(op='pair_confirm', id=pair['id'], code=pair['code'])
                    print('PASS Android/Linux TLS pairing with both-side code approval')

                data = os.urandom(256 * 1024 + 9)
                source = root / 'narad-generated-test.bin'
                source.write_bytes(data)
                offer = desktop(op='send_file', peer_id=phone_id, path=str(source))
                assert offer['status'] == 'pending'
                def cleanup_incoming():
                    with contextlib.suppress(RuntimeError):
                        phone(op='file_cancel', id=offer['id'])
                    phone(op='archive_transfer', id=offer['id'])
                    run('shell', 'run-as', PACKAGE, 'rm', '-rf', f"no_backup/narad/downloads/{offer['id']}")
                cleanup.append(cleanup_incoming)
                phone(op='file_accept', id=offer['id'])
                # Recreate the whole Android process, not just the Rust runtime.
                run('shell', 'am', 'force-stop', PACKAGE)
                for _ in range(100):
                    stopped = subprocess.run(adb + ['shell', 'pidof', PACKAGE], capture_output=True)
                    if stopped.returncode != 0:
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError('Android app did not stop before the restart test')
                run('shell', 'am', 'start', '-W', '-n', f'{PACKAGE}/.MainActivity')
                for _ in range(200):
                    candidate = subprocess.run(adb + ['shell', 'run-as', PACKAGE, 'cat', 'no_backup/narad/api-token'], capture_output=True)
                    if candidate.returncode == 0:
                        token = candidate.stdout.decode()
                        try:
                            restarted = phone(op='status')
                            if restarted['device']['device_id'] == phone_id:
                                break
                        except (OSError, RuntimeError):
                            pass
                    time.sleep(0.1)
                else:
                    raise RuntimeError('Android process restart timed out')
                assert host_id in restarted['paired']
                print('PASS Android process restart preserves identity, trust and file approval')
                received = desktop(op='send_file', peer_id=phone_id, path=str(source), id=offer['id'])
                assert received['status'] == 'completed'
                private_download = f"no_backup/narad/downloads/{offer['id']}/{source.name}"
                assert run('exec-out', 'run-as', PACKAGE, 'cat', private_download) == data
                print('PASS Desktop → Android approval and byte-for-byte file transfer')

                phone_source = f'{app_root}/cache/narad-e2e-{uuid.uuid4()}.bin'
                subprocess.run(adb + ['shell', '-T', 'run-as', PACKAGE, 'tee', phone_source], input=data, stdout=subprocess.DEVNULL, check=True)
                cleanup.append(lambda: run('shell', 'run-as', PACKAGE, 'rm', '-f', phone_source))
                outgoing = phone(op='send_file', peer_id=host_id, path=phone_source)
                assert outgoing['status'] == 'pending'
                desktop(op='file_accept', id=outgoing['id'])
                complete = phone(op='send_file', peer_id=host_id, path=phone_source, id=outgoing['id'])
                assert complete['status'] == 'completed'
                assert Path(complete['path']).read_bytes() == data
                cleanup.append(lambda: phone(op='archive_transfer', id=outgoing['id'], outgoing=True))
                print('PASS Android → desktop approval and byte-for-byte file transfer')

                try:
                    desktop(op='send_clipboard', peer_id=phone_id, text='Narad generated test')
                except RuntimeError as error:
                    assert 'permission denied' in str(error)
                else:
                    raise AssertionError('Clipboard must require permission')
                phone(op='permission', peer_id=host_id, capability='clipboard.sync', allow=True, automatic=False)
                clipboard = desktop(op='send_clipboard', peer_id=phone_id, text='Narad generated test')
                assert phone(op='clipboard_accept', id=clipboard['id'])['text'] == 'Narad generated test'
                print('PASS Android clipboard permission and acceptance (system clipboard untouched)')
                if args.controls:
                    deadline = time.monotonic() + 20
                    while not (phone(op='status')['presence'].get(host_id, {}).get('online') and desktop(op='status')['presence'].get(phone_id, {}).get('online')):
                        if time.monotonic() > deadline:
                            raise RuntimeError('Authenticated presence did not become online')
                        time.sleep(0.2)
                    print('PASS Android/Linux authenticated online presence')
                    phone(op='permission', peer_id=host_id, capability='file.transfer', allow=True)
                    automatic = desktop(op='send_file', peer_id=phone_id, path=str(source))
                    assert automatic['status'] == 'completed'
                    assert run('exec-out', 'run-as', PACKAGE, 'cat', f"no_backup/narad/downloads/{automatic['id']}/{source.name}") == data
                    def cleanup_automatic():
                        phone(op='archive_transfer', id=automatic['id'])
                        run('shell', 'run-as', PACKAGE, 'rm', '-rf', f"no_backup/narad/downloads/{automatic['id']}")
                    cleanup.append(cleanup_automatic)
                    print('PASS Persistent Android file grant transfers without another approval')
                    shared_name = f'narad-e2e-{uuid.uuid4()}.bin'
                    run('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'no_backup/narad/shared')
                    shared_path = f'{app_root}/no_backup/narad/shared/{shared_name}'
                    subprocess.run(adb + ['shell', '-T', 'run-as', PACKAGE, 'tee', shared_path], input=data, stdout=subprocess.DEVNULL, check=True)
                    cleanup.append(lambda: run('shell', 'run-as', PACKAGE, 'rm', '-f', shared_path))
                    phone(op='permission', peer_id=host_id, capability='file.browse', allow=True)
                    entries = desktop(op='browse_peer', peer_id=phone_id, path='')['entries']
                    assert any(e['name'] == shared_name for e in entries)
                    download = desktop(op='download_shared', peer_id=phone_id, path=shared_name)
                    assert Path(download['path']).read_bytes() == data
                    print('PASS Android Shared folder browse and byte-for-byte download')
                    preset = phone(op='command_set', label='Narad generated test', script='printf narad-android-fixture')
                    cleanup.append(lambda: phone(op='command_remove', id=preset['id']))
                    phone(op='permission', peer_id=host_id, capability='command.run', allow=True)
                    assert any(c['id'] == preset['id'] for c in desktop(op='list_commands', peer_id=phone_id)['commands'])
                    result = desktop(op='run_command', peer_id=phone_id, id=preset['id'])
                    assert result['stdout'] == 'narad-android-fixture', result
                    host_preset = desktop(op='command_set', label='Narad generated test', script='printf narad-linux-fixture')
                    desktop(op='permission', peer_id=phone_id, capability='command.run', allow=True)
                    assert phone(op='run_command', peer_id=host_id, id=host_preset['id'])['stdout'] == 'narad-linux-fixture'
                    print('PASS Preset command execution on both Android and Linux')
                    # Remove generated records while this temporary pairing is valid.
                    cleanup_automatic()
                    phone(op='command_remove', id=preset['id'])
                if args.widget:
                    import re
                    import xml.etree.ElementTree as ET
                    run('shell', 'appwidget', 'grantbind', '--package', PACKAGE)
                    try:
                        deadline=time.monotonic()+20
                        while not phone(op='status')['presence'].get(host_id,{}).get('online'):
                            if time.monotonic()>deadline:raise RuntimeError('Widget target not online')
                            time.sleep(0.2)
                        run('shell','am','start','-W','-n',f'{PACKAGE}/.WidgetPreviewActivity','--es','peer_id',host_id)
                        def ui():
                            run('shell','uiautomator','dump','/data/local/tmp/narad-widget-test.xml')
                            return ET.fromstring(run('exec-out','cat','/data/local/tmp/narad-widget-test.xml'))
                        deadline=time.monotonic()+25
                        while True:
                            tree=ui()
                            labels={node.get('text') for node in tree.iter('node')}
                            if 'Send file' in labels and 'Run command' in labels:break
                            if time.monotonic()>deadline:raise RuntimeError('Widget action rows did not inflate: '+str(labels))
                            time.sleep(0.5)
                        Path('/tmp/narad-device-widget.png').write_bytes(run('exec-out','screencap','-p'))
                        print('PASS real widget host renders device actions without requiring command presets')
                        if 'Device settings' not in labels:
                            view=next(node for node in tree.iter('node') if node.get('resource-id','').endswith('/widget_actions'))
                            x1,y1,x2,y2=map(int,re.findall(r'\d+',view.get('bounds')))
                            run('shell','input','swipe',str((x1+x2)//2),str(y2-30),str((x1+x2)//2),str(y1+30),'400')
                            tree=ui()
                        settings=next(node for node in tree.iter('node') if node.get('text')=='Device settings')
                        x1,y1,x2,y2=map(int,re.findall(r'\d+',settings.get('bounds')))
                        run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
                        deadline=time.monotonic()+20
                        while True:
                            tree=ui()
                            if any('Permissions · Narad Android test' in (node.get('text','')+node.get('content-desc','')) for node in tree.iter('node')):break
                            if time.monotonic()>deadline:
                                Path('/tmp/narad-widget-routing.xml').write_bytes(ET.tostring(tree))
                                raise RuntimeError('Widget settings action did not route to its paired device')
                            time.sleep(0.3)
                        print('PASS widget action opens settings for the selected paired device')
                        keys=run('shell','cmd','notification','list').decode().splitlines()
                        key=next((k.strip() for k in keys if PACKAGE in k and '|81|' in k),None)
                        assert key, 'Narad foreground connection notification is missing'
                        import shlex
                        detail=run('shell','cmd','notification','get',shlex.quote(key)).decode()
                        assert 'Narad Android test' in detail,detail
                        print('PASS persistent notification names the authenticated connected device')
                    finally:
                        run('shell','input','keyevent','KEYCODE_BACK')
                        run('shell','am','start','-W','-n',f'{PACKAGE}/.WidgetPreviewActivity','--activity-clear-top')
                        run('shell','input','keyevent','KEYCODE_BACK')
                        run('shell','appwidget','revokebind','--package',PACKAGE)
                        run('shell','rm','-f','/data/local/tmp/narad-widget-test.xml')
                        run('shell','am','start','-n',f'{PACKAGE}/.MainActivity')
                phone(op='unpair', peer_id=host_id)
                cleanup.pop(0)
                try:
                    desktop(op='ping_peer', peer_id=phone_id)
                except RuntimeError as error:
                    assert 'not paired' in str(error)
                else:
                    raise AssertionError('Revoked peer must be rejected')
                print('PASS Android revocation rejects previously paired desktop')
                if args.pairing == 'nearby':
                    desktop(op='unpair', peer_id=phone_id)
                    # The daemon must finish pairing even while Flutter is backgrounded.
                    run('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                    try:
                        pair = phone(op='pair_nearby', peer=discovered_host)
                        cleanup.append(lambda: phone(op='unpair', peer_id=host_id))
                        desktop(op='pair_approve', id=pair['id'], code=pair['code'])
                        deadline = time.monotonic() + 15
                        while host_id not in phone(op='status')['paired']:
                            if time.monotonic() > deadline:
                                raise RuntimeError('Background Android pairing did not complete')
                            time.sleep(0.1)
                        phone(op='ping_peer', peer_id=host_id)
                        phone(op='unpair', peer_id=host_id)
                        cleanup.pop()
                        print('PASS Background Android nearby request connects after desktop acceptance')
                    finally:
                        run('shell', 'am', 'start', '-n', f'{PACKAGE}/.MainActivity')
    finally:
        # A failure during process restart must still clean up the generated peer.
        if cleanup:
            for _ in range(100):
                candidate = subprocess.run(adb + ['shell', 'run-as', PACKAGE, 'cat', 'no_backup/narad/api-token'], capture_output=True)
                if candidate.returncode == 0:
                    token = candidate.stdout.decode()
                    try:
                        phone(op='status')
                        break
                    except (OSError, RuntimeError):
                        pass
                time.sleep(0.1)
        for action in reversed(cleanup):
            with contextlib.suppress(Exception):
                action()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        run('forward', '--remove', f'tcp:{forward}')


if __name__ == '__main__':
    main()
