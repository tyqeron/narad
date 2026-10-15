#!/usr/bin/env python3
"""Build native libraries for Gradle; Android NDK and Rust targets must be installed."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--ndk', required=True, type=Path)
parser.add_argument('--abis', default='arm64-v8a,armeabi-v7a,x86_64')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
host = {'Linux': 'linux-x86_64', 'Darwin': 'darwin-x86_64', 'Windows': 'windows-x86_64'}[platform.system()]
bin_dir = args.ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
targets = {
    'arm64-v8a': ('aarch64-linux-android', 'aarch64-linux-android26-clang'),
    'armeabi-v7a': ('armv7-linux-androideabi', 'armv7a-linux-androideabi26-clang'),
    'x86_64': ('x86_64-linux-android', 'x86_64-linux-android26-clang'),
}
for abi in args.abis.split(','):
    if abi not in targets:
        parser.error(f'Unsupported ABI: {abi}')
    target, compiler = targets[abi]
    compiler_path = bin_dir / (compiler + ('.cmd' if os.name == 'nt' else ''))
    if not compiler_path.is_file():
        parser.error(f'NDK compiler not found: {compiler_path}')
    env = os.environ.copy()
    cargo_target = target.upper().replace('-', '_')
    cc_target = target.replace('-', '_')
    env[f'CARGO_TARGET_{cargo_target}_LINKER'] = str(compiler_path)
    env[f'CC_{cc_target}'] = str(compiler_path)
    env[f'AR_{cc_target}'] = str(bin_dir / ('llvm-ar.exe' if os.name == 'nt' else 'llvm-ar'))
    # Support Android devices with either 4 KiB or 16 KiB memory pages on NDK r27+.
    env[f'CARGO_TARGET_{cargo_target}_RUSTFLAGS'] = '-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
    subprocess.run(['cargo', 'build', '--locked', '--release', '-p', 'narad-android', '--target', target], cwd=root, env=env, check=True)
    destination = root / 'clients/flutter/android/app/build/generated/rustJniLibs' / abi
    destination.mkdir(parents=True, exist_ok=True)
    # Cargo may use an external target directory; read its configured location.
    import json
    metadata = subprocess.check_output(['cargo', 'metadata', '--format-version', '1', '--no-deps', '--offline'], cwd=root, env=env)
    target_dir = Path(json.loads(metadata)['target_directory'])
    shutil.copy2(target_dir / target / 'release/libnarad_android.so', destination / 'libnarad_android.so')
