#!/usr/bin/env python3
"""Release gates: matching versions, prereleases, and Android build numbers."""
import importlib.util
from pathlib import Path
import unittest

source = Path(__file__).resolve().parents[1] / 'scripts/release-metadata.py'
spec = importlib.util.spec_from_file_location('release_metadata', source)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseMetadataTests(unittest.TestCase):
    def test_tag_matches_embedded_version_without_changing_build_number(self):
        for tag in ['v0.2.0', '0.2.0']:
            self.assertEqual(release.metadata(tag, 'version: 0.2.0+13\n'),
                             {'version': '0.2.0', 'build_number': '13', 'prerelease': 'false'})

    def test_prerelease_is_not_published_as_stable(self):
        self.assertEqual(release.metadata('v0.2.0-beta.1', "version: '0.2.0-beta.1+14' # test\n")['prerelease'], 'true')

    def test_tag_and_binary_version_must_agree(self):
        with self.assertRaisesRegex(ValueError, 'does not match'):
            release.metadata('v0.2.0', 'version: 0.1.0+12\n')

    def test_invalid_tag_cannot_reach_publication(self):
        for tag in ['latest', 'v01.2.3', 'v0.2.0-beta.01', 'v0.2.0\nprerelease=false', '--draft']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.metadata(tag, 'version: 0.2.0+13\n')

    def test_android_version_code_is_required_and_bounded(self):
        for version in ['0.2.0', '0.2.0+0', '0.2.0+2100000001', '0.2.0+abc']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.metadata('v0.2.0', f'version: {version}\n')


if __name__ == '__main__':
    unittest.main()
