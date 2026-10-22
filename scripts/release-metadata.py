#!/usr/bin/env python3
"""Validate a release tag against the app version and emit GitHub job outputs."""
import os
from pathlib import Path
import re
import sys


def metadata(tag, pubspec):
    version = tag.removeprefix('v')
    match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?', version)
    if not match or any(p.isdigit() and len(p) > 1 and p.startswith('0') for p in (match[4] or '').split('.')):
        raise ValueError('Use a version tag such as v0.1.0 or v0.2.0-beta.1')
    app = re.search(r'^version:\s*[\'"]?([^\s\'"#]+)[\'"]?\s*(?:#.*)?$', pubspec, re.MULTILINE)
    if not app:
        raise ValueError('pubspec.yaml must declare version: VERSION+BUILD_NUMBER')
    name, _, build = app[1].partition('+')
    if name != version:
        raise ValueError(f'Tag version {version} does not match pubspec version {name}. Update clients/flutter/pubspec.yaml, commit it, and tag that commit; rerunning the old tag uses its original version.')
    if not build.isascii() or not build.isdigit() or not 1 <= int(build) <= 2_100_000_000:
        raise ValueError('App build number must be between 1 and 2100000000')
    return {'version': version, 'build_number': str(int(build)), 'prerelease': str(bool(match[4])).lower()}


if __name__ == '__main__':
    try:
        root = Path(__file__).resolve().parents[1]
        result = metadata(os.environ['GITHUB_REF_NAME'], (root / 'clients/flutter/pubspec.yaml').read_text())
        output = ''.join(f'{key}={value}\n' for key, value in result.items())
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
                stream.write(output)
        print(output, end='')
    except (KeyError, ValueError) as error:
        sys.exit(f'Release configuration error: {error}')
