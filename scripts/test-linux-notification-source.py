#!/usr/bin/env python3
"""Synthetic notification source tests on an isolated session bus and display."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import threading
import time
import gi

gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

if os.environ.get('NARAD_NOTIFICATION_TEST_BUS') != '1':
    raise SystemExit('Run with dbus-run-session -- env NARAD_NOTIFICATION_TEST_BUS=1 /usr/bin/python3 scripts/test-linux-notification-source.py')
root = Path(__file__).resolve().parents[1]
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
threading.Thread(target=loop.run, daemon=True).start()
xml = '''<node><interface name="org.freedesktop.Notifications">
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface></node>'''
info = Gio.DBusNodeInfo.new_for_xml(xml)
sequence = 0
closed = []

def server(conn, sender, path, interface, method, args, invocation):
    global sequence
    values = args.unpack()
    if method == 'Notify':
        sequence += 1
        invocation.return_value(GLib.Variant('(u)', (values[1] or sequence,)))
    else:
        closed.append(values[0])
        invocation.return_value(None)
        conn.emit_signal(None, path, interface, 'NotificationClosed', GLib.Variant('(uu)', (values[0], 3)))

registration = bus.register_object('/org/freedesktop/Notifications', info.interfaces[0], server, None, None)
bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
    GLib.Variant('(su)', ('org.freedesktop.Notifications', 0)), None, Gio.DBusCallFlags.NONE, 3000, None)

def notify(title, replace=0, mirrored=False, progress=None, ongoing=False):
    hints = {'x-narad-mirrored': GLib.Variant('b', True)} if mirrored else {}
    hints['resident'] = GLib.Variant('b', ongoing)
    if progress is not None: hints['value'] = GLib.Variant('i', progress)
    return bus.call_sync('org.freedesktop.Notifications', '/org/freedesktop/Notifications',
        'org.freedesktop.Notifications', 'Notify', GLib.Variant('(susssasa{sv}i)',
        ('Fixture app', replace, str(root/'clients/flutter/assets/branding/narad.png'), title, '<b>Generated body</b>', [], hints, 0)),
        None, Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]

with tempfile.TemporaryDirectory(prefix='narad-source-test-') as folder:
    runner = root/'clients/flutter/linux/runner'
    binary = str(Path(folder)/'source-test')
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk+-3.0'], text=True))
    subprocess.run(['c++', '-std=c++14', '-Wall', '-Werror', '-I'+str(runner),
        str(runner/'tests/notification_source_harness.cc'), str(runner/'notification_source.cc'), '-o', binary, *flags], check=True)
    env = dict(os.environ, XDG_CONFIG_HOME=folder, GTK_USE_PORTAL='0', NO_AT_BRIDGE='1')
    process = subprocess.Popen([binary], stdout=subprocess.PIPE, text=True, env=env)
    try:
        sender = process.stdout.readline().strip()
        assert sender.startswith(':')
        def call(method, signature=None, values=()):
            return bus.call_sync(sender, '/Source', 'dev.narad.SourceTest', method,
                GLib.Variant(signature, values) if signature else None,
                None, Gio.DBusCallFlags.NONE, 5000, None).unpack()
        def items():
            return call('List')[0]
        def wait(check):
            deadline = time.monotonic()+5
            while not check():
                assert time.monotonic()<deadline, 'Notification capture did not converge'
                time.sleep(.05)
        notify('Before opt-in'); assert items() == []
        call('Enable', '(b)', (True,))
        id = notify('Initial fixture'); wait(lambda: len(items()) == 1)
        assert items()[0]['key'] == 'linux:'+str(id)
        assert items()[0]['title'] == 'Initial fixture'
        assert items()[0]['app'] == 'Fixture app'
        assert items()[0]['text'] == 'Generated body'
        import base64, struct
        icon=base64.b64decode(items()[0]['icon'])
        assert struct.unpack('>II',icon[16:24])==(32,32)
        assert items()[0]['actions'] == [] and not items()[0]['reply']
        notify('Updated fixture', id, progress=75, ongoing=True); wait(lambda: items()[0]['title'] == 'Updated fixture')
        assert len(items()) == 1
        assert items()[0]['ongoing'] and items()[0]['progress'] == 75 and items()[0]['progressMax'] == 100
        call('Own'); notify('Mirrored fixture', mirrored=True); time.sleep(.2)
        assert len(items()) == 1, 'Mirrored/own notification loop'
        call('Dismiss', '(s)', ('linux:'+str(id),)); wait(lambda: items() == [])
        assert id in closed
        # Restart the notification service under a different unique bus owner.
        bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReleaseName',
            GLib.Variant('(s)', ('org.freedesktop.Notifications',)), None, Gio.DBusCallFlags.NONE, 3000, None)
        replacement = Gio.DBusConnection.new_for_address_sync(GLib.getenv('DBUS_SESSION_BUS_ADDRESS'),
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        replacement.register_object('/org/freedesktop/Notifications', info.interfaces[0], server, None, None)
        replacement.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
            GLib.Variant('(su)', ('org.freedesktop.Notifications', 0)), None, Gio.DBusCallFlags.NONE, 3000, None)
        assert call('Status')[0]['enabled']
        notify('After service restart'); wait(lambda: len(items()) == 1)
        call('Enable', '(b)', (False,)); notify('After opt-out'); time.sleep(.1)
        assert items() == []
        call('Quit'); assert process.wait(timeout=5) == 0
        print('PASS opt-in, capture, server IDs, replacement, no loops, dismiss, service restart and opt-out')
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=5)
bus.unregister_object(registration)
loop.quit()
