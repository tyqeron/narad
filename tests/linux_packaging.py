"""Check a generated Linux installer using disposable prefixes and generated data."""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, success=True, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if (result.returncode == 0) != success:
        raise AssertionError(result.stdout + result.stderr)
    return result


def port_pair():
    for _ in range(100):
        with socket.socket() as first, socket.socket() as second:
            first.bind(('127.0.0.1', 0))
            port = first.getsockname()[1]
            if port == 65535:
                continue
            try:
                second.bind(('127.0.0.1', port + 1))
                return port
            except OSError:
                pass
    raise RuntimeError('No ports available')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('installer', type=Path)
    args = parser.parse_args()
    installer = args.installer.resolve()
    with tempfile.TemporaryDirectory(prefix='narad-package-test-') as directory:
        root = Path(directory)
        prefix = root / 'Apps with spaces' / 'Narad'
        env = dict(os.environ, XDG_DATA_HOME=str(root / 'user data'))
        run('bash', str(installer), '--help', env=env)
        run('bash', str(installer), '--prefix', str(prefix), env=env)
        assert (prefix / '.narad-install').is_file()
        assert (prefix / 'app/narad_client').is_file()
        desktop = root / 'user data/applications/dev.narad.narad_client.desktop'
        assert str(prefix / 'narad-linux') in desktop.read_text()
        if shutil.which('desktop-file-validate'):
            run('desktop-file-validate', str(desktop))
        print('PASS per-user installation and desktop entry with spaces')
        state = root / 'user data/narad'
        state.mkdir()
        sentinel = state / 'generated-preservation-fixture'
        sentinel.write_text('preserve this generated test data')
        (prefix / 'obsolete-fixture').touch()
        run('bash', str(installer), '--prefix', str(prefix), env=env)
        assert sentinel.read_text() == 'preserve this generated test data'
        assert not (prefix / 'obsolete-fixture').exists()
        print('PASS upgrade replaces application files and preserves separate state')
        foreign = root / 'unrelated directory'
        foreign.mkdir()
        fixture = foreign / 'keep'
        fixture.write_text('keep')
        run('bash', str(installer), '--prefix', str(foreign), env=env, success=False)
        assert fixture.read_text() == 'keep'
        link = root / 'linked directory'
        link.symlink_to(foreign, target_is_directory=True)
        run('bash', str(installer), '--prefix', str(link), env=env, success=False)
        print('PASS unrelated directories and symlink destinations are rejected')
        corrupt = root / 'corrupt.run'
        shutil.copyfile(installer, corrupt)
        with corrupt.open('ab') as output:
            output.write(b'corrupt-payload-fixture')
        result = run('bash', str(corrupt), '--prefix', str(root / 'rejected'), env=env, success=False)
        assert 'checksum mismatch' in result.stderr
        assert not (root / 'rejected').exists()
        print('PASS corrupt payload is rejected before installation')

        # Exercise the actual packaged daemon and launcher, with a headless test GUI.
        app = root / 'launcher fixture'
        (app / 'app').mkdir(parents=True)
        shutil.copy2(prefix / 'narad', app / 'narad')
        shutil.copy2(prefix / 'narad-linux', app / 'narad-linux')
        gui = app / 'app/narad_client'
        gui.write_text('#!/usr/bin/env bash\nset -eu\n../narad --state "$NARAD_STATE" --api-port "$NARAD_API_PORT" status >/dev/null\n')
        gui.chmod(0o755)
        api = port_pair()
        control = port_pair()
        while api in (control, control + 1):
            api = port_pair()
        launch_env = dict(env, NARAD_STATE=str(root / 'daemon state'),
                          NARAD_API_PORT=str(api), NARAD_CONTROL_PORT=str(control))
        run(str(app / 'narad-linux'), env=launch_env, timeout=30)
        with socket.socket() as probe:
            assert probe.connect_ex(('127.0.0.1', api)) != 0, 'Owned daemon survived GUI exit'
        print('PASS launcher starts authenticated backend and stops it when GUI exits')

        daemon = subprocess.Popen([str(app / 'narad'), '--state', launch_env['NARAD_STATE'],
                                   '--api-port', str(api), 'serve', '--port', str(control),
                                   '--no-discovery'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            import time
            for _ in range(100):
                result = subprocess.run([str(app / 'narad'), '--state', launch_env['NARAD_STATE'],
                                         '--api-port', str(api), 'status'], capture_output=True)
                if result.returncode == 0:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('Fixture daemon did not become ready')
            run(str(app / 'narad-linux'), env=launch_env, timeout=30)
            assert daemon.poll() is None, 'Launcher stopped a reused daemon'
            print('PASS launcher reuses and preserves an existing authenticated daemon')
        finally:
            daemon.terminate()
            daemon.wait(timeout=10)


if __name__ == '__main__':
    main()
