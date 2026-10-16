"""Opt-in native GTK hide/restore check; run inside an isolated Xvfb + D-Bus session."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time
from e2e import Device


def request_close(window):
    # WM_DELETE_WINDOW follows the same path as the title-bar close button.
    # XDestroyWindow (some xdotool versions' windowclose) bypasses GTK handlers.
    import ctypes as c
    class Data(c.Union):
        _fields_=[('l',c.c_long*5),('b',c.c_char*20)]
    class Client(c.Structure):
        _fields_=[('type',c.c_int),('serial',c.c_ulong),('send_event',c.c_int),
                  ('display',c.c_void_p),('window',c.c_ulong),('message_type',c.c_ulong),
                  ('format',c.c_int),('data',Data)]
    class Event(c.Union):
        _fields_=[('client',Client),('padding',c.c_long*24)]
    x=c.CDLL('libX11.so.6')
    x.XOpenDisplay.argtypes=[c.c_char_p];x.XOpenDisplay.restype=c.c_void_p
    x.XInternAtom.argtypes=[c.c_void_p,c.c_char_p,c.c_int];x.XInternAtom.restype=c.c_ulong
    x.XSendEvent.argtypes=[c.c_void_p,c.c_ulong,c.c_int,c.c_long,c.POINTER(Event)]
    x.XFlush.argtypes=[c.c_void_p];x.XCloseDisplay.argtypes=[c.c_void_p]
    display=x.XOpenDisplay(None)
    assert display
    try:
        event=Event()
        event.client.type=33
        event.client.display=display
        event.client.window=int(window)
        event.client.message_type=x.XInternAtom(display,b'WM_PROTOCOLS',0)
        event.client.format=32
        event.client.data.l[0]=x.XInternAtom(display,b'WM_DELETE_WINDOW',0)
        assert x.XSendEvent(display,int(window),0,0,c.byref(event))
        x.XFlush(display)
    finally:x.XCloseDisplay(display)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle',type=Path)
    args=parser.parse_args()
    executable=(args.bundle/'narad_client').resolve()
    assert os.environ.get('DISPLAY') and os.environ.get('DBUS_SESSION_BUS_ADDRESS'), 'Use isolated Xvfb + dbus-run-session'
    with tempfile.TemporaryDirectory(prefix='narad-background-') as temporary:
        root=Path(temporary)
        device=Device(root,'Background fixture')
        app=None
        try:
            env=dict(os.environ,NARAD_STATE=str(device.state),NARAD_API_PORT=str(device.api),
                     XDG_CONFIG_HOME=str(root/'config'),XDG_DATA_HOME=str(root/'data'),
                     LIBGL_ALWAYS_SOFTWARE='1', GDK_BACKEND='x11')
            with (root/'gui.log').open('w') as log:
                app=subprocess.Popen([str(executable),'--background'],env=env,stdout=log,stderr=log)
                def windows(visible=False):
                    command=['xdotool','search']+(['--onlyvisible'] if visible else [])+['--name','^Narad$']
                    return subprocess.run(command,env=env,capture_output=True,text=True).stdout.splitlines()
                def wait(predicate,message):
                    deadline=time.monotonic()+25
                    while time.monotonic()<deadline:
                        if app.poll() is not None:
                            raise AssertionError((root/'gui.log').read_text())
                        if predicate():return
                        time.sleep(0.1)
                    raise AssertionError(message+'\n'+(root/'gui.log').read_text())
                wait(lambda:bool(windows()),'Native window did not initialize')
                time.sleep(2)
                assert not windows(True), 'Background startup showed a window'
                device.call(op='status')
                print('PASS login-style startup stays hidden and backend remains reachable',flush=True)
                subprocess.run([str(executable)],env=env,check=True,timeout=15,stdout=log,stderr=log)
                wait(lambda:bool(windows(True)),'Second launch did not restore the existing window')
                window=windows(True)[0]
                request_close(window)
                wait(lambda:not windows(True),'Closing window did not hide it')
                assert app.poll() is None
                device.call(op='status')
                print('PASS closing the window preserves the live app and backend',flush=True)
                subprocess.run([str(executable)],env=env,check=True,timeout=15,stdout=log,stderr=log)
                wait(lambda:bool(windows(True)),'Hidden app did not reopen')
                print('PASS application-menu relaunch restores the same process',flush=True)
        finally:
            if app is not None and app.poll() is None:
                app.terminate()
                app.wait(timeout=10)
            device.stop()


if __name__=='__main__':main()
