#!/usr/bin/env python3
"""Check universal backend packaging and ELF alignment without executing APK code."""
import argparse
from pathlib import Path
import struct
import zipfile


def verify(path):
    abis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'}
    checked = 0
    with zipfile.ZipFile(path) as apk:
        for abi in abis:
            if f'lib/{abi}/libnarad_android.so' not in apk.namelist():
                raise ValueError(f'Missing embedded backend for {abi}')
        for name in apk.namelist():
            if not name.endswith('.so') or not name.startswith(('lib/arm64-v8a/', 'lib/x86_64/')):
                continue
            data = apk.read(name)
            if data[:4] != b'\x7fELF' or data[5] != 1:
                raise ValueError(f'Unexpected ELF format: {name}')
            wide = data[4] == 2
            offset = struct.unpack_from('<Q' if wide else '<I', data, 32 if wide else 28)[0]
            size, count = struct.unpack_from('<HH', data, 54 if wide else 42)
            alignments = [
                struct.unpack_from('<Q' if wide else '<I', data, offset + i * size + (48 if wide else 28))[0]
                for i in range(count)
                if struct.unpack_from('<I', data, offset + i * size)[0] == 1
            ]
            if not alignments or min(alignments) < 16384:
                raise ValueError(f'ELF segments are not 16 KiB aligned: {name}')
            checked += 1
    print(f'PASS universal APK: 3 backend ABIs; {checked} aligned 64-bit native libraries')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    verify(parser.parse_args().apk)
