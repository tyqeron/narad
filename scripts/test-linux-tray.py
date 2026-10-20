#!/usr/bin/env python3
"""Exercise the native tray on an isolated bus; requires GTK, PyGObject and a display.
Run after a Linux Flutter build:
  dbus-run-session -- env NARAD_TRAY_TEST_BUS=1 /usr/bin/python3 scripts/test-linux-tray.py
"""
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

root = Path(__file__).resolve().parents[1]
# Avoid registering a test watcher on the user's desktop bus.
if os.environ.get('NARAD_TRAY_TEST_BUS') != '1':
    raise SystemExit('Run: dbus-run-session -- env NARAD_TRAY_TEST_BUS=1 /usr/bin/python3 scripts/test-linux-tray.py')
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
thread = threading.Thread(target=loop.run, daemon=True)
thread.start()
registrations = []
xml = '<node><interface name="org.kde.StatusNotifierWatcher"><method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method></interface></node>'
info = Gio.DBusNodeInfo.new_for_xml(xml)

def register(conn, sender, path, interface, method, args, invocation):
    registrations.append((sender, args.unpack()[0]))
    invocation.return_value(None)

obj = bus.register_object('/StatusNotifierWatcher', info.interfaces[0], register, None, None)

def name(op):
    return bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', op,
        GLib.Variant('(su)', ('org.kde.StatusNotifierWatcher', 0)) if op == 'RequestName' else GLib.Variant('(s)', ('org.kde.StatusNotifierWatcher',)),
        None, Gio.DBusCallFlags.NONE, 3000, None)

def wait(predicate):
    deadline = time.monotonic() + 8
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError('Tray operation timed out')
        time.sleep(.05)

with tempfile.TemporaryDirectory(prefix='narad-tray-test-') as folder:
    binary = str(Path(folder) / 'tray-test')
    runner = root / 'clients/flutter/linux/runner'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk+-3.0'], text=True))
    subprocess.run(['c++', '-std=c++14', '-Wall', '-Werror', '-I'+str(runner),
        '-I'+str(root/'clients/flutter/linux/flutter/ephemeral'),
        str(runner/'tests/tray_harness.cc'), str(runner/'system_tray.cc'), '-o', binary, *flags], check=True)
    name('RequestName')
    icon = root / 'clients/flutter/build/linux/x64/debug/bundle/data/narad.png'
    assert icon.is_file()
    process = subprocess.Popen([binary, str(icon)], stdout=subprocess.PIPE, text=True)
    try:
        sender = process.stdout.readline().strip()
        assert sender.startswith(':')
        wait(lambda: len(registrations) == 1)
        assert registrations[0] == (sender, '/StatusNotifierItem')
        def call(path, interface, method, signature=None, values=()):
            return bus.call_sync(sender, path, interface, method,
                GLib.Variant(signature, values) if signature else None, None, Gio.DBusCallFlags.NONE, 3000, None).unpack()
        props = call('/StatusNotifierItem', 'org.freedesktop.DBus.Properties', 'GetAll', '(s)', ('org.kde.StatusNotifierItem',))[0]
        assert props['Title'] == 'Narad' and props['Status'] == 'Active'
        assert props['IconPixmap'][0][:2] == (32, 32)
        assert len(props['IconPixmap'][0][2]) == 32*32*4
        revision, layout = call('/MenuBar', 'com.canonical.dbusmenu', 'GetLayout', '(iias)', (0, -1, []))
        assert revision == 1 and [item[1]['label'] for item in layout[2]] == ['Open Narad', 'Quit Narad']
        assert not call('/Test', 'dev.narad.TrayTest', 'Visible')[0]
        call('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'Activate', '(ii)', (0, 0))
        assert call('/Test', 'dev.narad.TrayTest', 'Visible')[0]
        call('/Test', 'dev.narad.TrayTest', 'Hide')
        call('/MenuBar', 'com.canonical.dbusmenu', 'Event', '(isvu)', (1, 'clicked', GLib.Variant('i', 0), 0))
        assert call('/Test', 'dev.narad.TrayTest', 'Visible')[0]
        name('ReleaseName'); time.sleep(.15); name('RequestName')
        wait(lambda: len(registrations) == 2)
        call('/MenuBar', 'com.canonical.dbusmenu', 'Event', '(isvu)', (2, 'clicked', GLib.Variant('i', 0), 0))
        assert process.wait(timeout=5) == 0
        print('PASS tray registration, icon pixels, menu, Activate, Open, watcher restart and Quit')
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=5)
        name('ReleaseName')
bus.unregister_object(obj)
loop.quit()
