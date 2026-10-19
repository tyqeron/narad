#!/usr/bin/env python3
"""Own one portal-created virtual monitor; closing this process removes it."""
import json
import os
import sys
import uuid
import shutil
import subprocess
import time
from collections import Counter
from pathlib import Path

BUS = 'org.freedesktop.portal.Desktop'
PATH = '/org/freedesktop/portal/desktop'
IFACE = 'org.freedesktop.portal.ScreenCast'
connection = None
PARENT_PID = os.getppid()


def watch_parent(loop):
    source = GLib.timeout_source_new_seconds(2)
    def check(*_):
        if os.getppid() != PARENT_PID:
            loop.quit()
            return False
        return True
    source.set_callback(check)
    source.attach(None)
    return source


def property_value(name):
    reply = connection.call_sync(BUS, PATH, 'org.freedesktop.DBus.Properties', 'Get',
                                 GLib.Variant('(ss)', (IFACE, name)), None,
                                 Gio.DBusCallFlags.NONE, 5000, None)
    return reply.unpack()[0]


def request(method, signature, args):
    token = 'narad_' + uuid.uuid4().hex
    options = args[-1]
    options['handle_token'] = GLib.Variant('s', token)
    path = '/org/freedesktop/portal/desktop/request/' + connection.get_unique_name()[1:].replace('.', '_') + '/' + token
    loop = GLib.MainLoop()
    result = []
    def response(_connection, _sender, _path, _interface, _signal, parameters):
        result.append(parameters.unpack())
        loop.quit()
    subscription = connection.signal_subscribe(BUS, 'org.freedesktop.portal.Request', 'Response', path,
                                               None, Gio.DBusSignalFlags.NONE, response)
    timer = GLib.timeout_add_seconds(120, lambda: (loop.quit(), False)[1])
    watchdog = watch_parent(loop)
    try:
        connection.call_sync(BUS, PATH, IFACE, method, GLib.Variant(signature, args),
                             None, Gio.DBusCallFlags.NONE, 10000, None)
        if not result:
            loop.run()
        if not result or result[0][0] != 0:
            raise RuntimeError('Virtual display selection was cancelled or unavailable')
        return result[0][1]
    finally:
        watchdog.destroy()
        connection.signal_unsubscribe(subscription)
        if result:
            GLib.source_remove(timer)


def select_new_output(before, current):
    previous = Counter(item['name'] for item in before)
    present = Counter(item['name'] for item in current)
    candidates = [item for item in current if item.get('connected')
                  and item['name'].startswith('Virtual-')
                  and present[item['name']] > previous[item['name']]]
    if len(candidates) == 1:
        return candidates[0]
    # KDE can use the same connector name for several portal sessions. Already
    # configured Narad outputs are independent; the new one starts as a replica.
    mirrored = [item for item in candidates if item.get('replicationSource', 0) != 0]
    return mirrored[0] if len(mirrored) == 1 else None


def outputs():
    if not shutil.which('kscreen-doctor'):
        return None
    result = subprocess.run(['kscreen-doctor', '-j'], capture_output=True, text=True, timeout=5, check=True)
    return json.loads(result.stdout).get('outputs', [])


def extend_new_output(before):
    if before is None:
        return None
    monitor = None
    for _ in range(20):
        monitor = select_new_output(before, outputs())
        if monitor:
            break
        time.sleep(.1)
    if monitor is None:
        raise RuntimeError('Cannot identify the newly created virtual monitor')
    right = max((item.get('pos', {}).get('x', 0) + item.get('size', {}).get('width', 0)
                 for item in before if item.get('enabled')), default=0)
    result = subprocess.run(['kscreen-doctor', f"output.{monitor['id']}.mirror.none",
                             f"output.{monitor['id']}.position.{right},0"], capture_output=True, text=True, timeout=8)
    configured = next(item for item in outputs() if item['id'] == monitor['id'])
    if result.returncode != 0 or configured.get('replicationSource', 0) != 0:
        raise RuntimeError('The compositor did not switch the virtual monitor into extend mode')
    return configured['name']


def display_identity(data_home):
    app_id = 'dev.narad.narad_client.display' + uuid.uuid4().hex
    directory = Path(data_home) / 'applications'
    directory.mkdir(parents=True, exist_ok=True)
    desktop = directory / (app_id + '.desktop')
    with desktop.open('x') as entry:
        entry.write('[Desktop Entry]\nType=Application\nName=Narad display ' + app_id[-6:] +
                    '\nExec=false\nNoDisplay=true\nIcon=dev.narad.narad_client\n')
    return desktop


def capture(app_id):
    registered = False
    try:
        # Identify this helper as Narad even when launched from an IDE or shell.
        connection.call_sync(BUS, PATH, 'org.freedesktop.host.portal.Registry',
                             'Register', GLib.Variant('(sa{sv})', (app_id, {})),
                             None, Gio.DBusCallFlags.NONE, 5000, None)
        registered = True
    except GLib.Error:
        pass  # Older portals determine application identity themselves.
    supported = bool(property_value('AvailableSourceTypes') & 4)
    if '--check' in sys.argv:
        print(json.dumps({'supported': supported and registered}), flush=True)
        return
    if not registered:
        raise RuntimeError('The portal cannot register independent Narad displays; update xdg-desktop-portal')
    if not supported:
        raise RuntimeError('This compositor does not provide virtual monitors through the screen portal')
    session = None
    fd = None
    try:
        before = outputs()
        created = request('CreateSession', '(a{sv})', ({'session_handle_token': GLib.Variant('s', 'narad_' + uuid.uuid4().hex)},))
        session = created['session_handle']
        request('SelectSources', '(oa{sv})', (session, {'types': GLib.Variant('u', 4), 'multiple': GLib.Variant('b', False)}))
        started = request('Start', '(osa{sv})', (session, '', {}))
        streams = started.get('streams', [])
        if len(streams) != 1:
            raise RuntimeError('The compositor did not create one virtual monitor')
        node, properties = streams[0]
        if properties.get('source_type', 4) != 4:
            raise RuntimeError('The selected source is not a virtual monitor')
        response, fds = connection.call_with_unix_fd_list_sync(
            BUS, PATH, IFACE, 'OpenPipeWireRemote', GLib.Variant('(oa{sv})', (session, {})),
            None, Gio.DBusCallFlags.NONE, 10000, None, None)
        fd = fds.get(response.unpack()[0])
        # Keeping the portal session (and its remote FD) alive owns the output.
        # A second screen-capture session streams this monitor to WebRTC.
        monitor = extend_new_output(before)
        loop = GLib.MainLoop()
        connection.signal_subscribe(BUS, 'org.freedesktop.portal.Session', 'Closed', session,
                                    None, Gio.DBusSignalFlags.NONE, lambda *_: loop.quit())
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, lambda: (loop.quit(), False)[1])
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 2, lambda: (loop.quit(), False)[1])
        print(json.dumps({'ready': True, 'node': node, 'size': properties.get('size'), 'monitor': monitor}), flush=True)
        watchdog = watch_parent(loop)
        try:
            loop.run()
        finally:
            watchdog.destroy()
    finally:
        if fd is not None:
            os.close(fd)
        if session:
            try:
                connection.call_sync(BUS, session, 'org.freedesktop.portal.Session', 'Close', None,
                                     None, Gio.DBusCallFlags.NONE, 5000, None)
            except GLib.Error:
                pass  # The portal may have already closed a cancelled session.


def main():
    global Gio, GLib, connection
    from gi.repository import Gio, GLib
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    if '--check' in sys.argv:
        capture('dev.narad.narad_client')
        return
    # KDE names virtual connectors using the app id. Give each output its own
    # registered, hidden Narad descriptor so two displays cannot share a layout.
    desktop = display_identity(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
    try:
        capture(desktop.stem)
    finally:
        desktop.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error)}), flush=True)
        sys.exit(1)
