import copy
import unittest
from pathlib import Path
import tempfile
from unittest.mock import patch
import xml.etree.ElementTree as XML

import publish_update
from prepare_update import ASSET_SUFFIXES, REPOSITORY, SPARKLE_NS
from publish_update import installer_names


class PublicationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'version': '0.2.5', 'platforms': {
            platform: {'url': f'https://github.com/{REPOSITORY}/releases/download/v0.2.5/Silique-0.2.5{suffix}'}
            for platform, suffix in ASSET_SUFFIXES.items()
        }}

    def test_all_platforms_and_existing_two_platform_release(self):
        self.assertEqual(len(installer_names(self.manifest)), 7)
        self.assertEqual(ASSET_SUFFIXES.get('macos-dmg'), '-macOS.dmg')
        self.assertNotIn('macos', ASSET_SUFFIXES)
        self.manifest['platforms'] = {key: self.manifest['platforms'][key] for key in ['macos-dmg', 'android']}
        self.assertEqual(set(installer_names(self.manifest)), {'Silique-0.2.5-macOS.dmg', 'Silique-0.2.5.apk'})

    def test_reject_legacy_macos_zip_even_alongside_dmg(self):
        self.manifest['platforms']['macos'] = {'url': 'Silique-0.2.5-macOS.zip'}
        with self.assertRaises(ValueError):
            installer_names(self.manifest)

    def test_reject_unreviewed_assets_and_path_traversal(self):
        for url in ['../../source.zip', 'https://example.com/installer.exe',
                    f'https://github.com/{REPOSITORY}/releases/download/v0.2.5/source.zip']:
            with self.subTest(url=url):
                changed = copy.deepcopy(self.manifest)
                changed['platforms']['windows']['url'] = url
                with self.assertRaises(ValueError):
                    installer_names(changed)
        self.manifest['platforms']['source'] = {'url': 'source.zip'}
        with self.assertRaises(ValueError):
            installer_names(self.manifest)

    def test_publication_checks_dmg_and_matching_appcast_before_upload(self):
        self.assertTrue(hasattr(publish_update, 'verify_prepared_macos'), 'Native prepared DMG publication gate is missing')
        manifest = copy.deepcopy(self.manifest)
        manifest['build'] = 14
        manifest['platforms']['macos-dmg']['size'] = 123
        with tempfile.TemporaryDirectory() as folder, patch.object(publish_update, 'run') as run, \
                patch.object(publish_update, 'verify_dmg') as verify:
            source = Path(folder)
            rss = XML.Element('rss')
            item = XML.SubElement(XML.SubElement(rss, 'channel'), 'item')
            XML.SubElement(item, 'description').text = 'Public notes'
            enclosure = XML.SubElement(item, 'enclosure', {
                'url': manifest['platforms']['macos-dmg']['url'], 'length': '123',
                f'{{{SPARKLE_NS}}}version': '14', f'{{{SPARKLE_NS}}}shortVersionString': '0.2.5',
                f'{{{SPARKLE_NS}}}edSignature': 'fixture-not-real-signature'})
            feed = source / 'appcast.xml'
            XML.ElementTree(rss).write(feed)
            publish_update.verify_prepared_macos(source, manifest, 'Public notes')
            verify.assert_called_once_with(source / 'Silique-0.2.5-macOS.dmg', '0.2.5', 14)
            self.assertTrue(any(str(source / 'Silique-0.2.5-macOS.dmg') in call.args for call in run.call_args_list))
            for attribute, value in [('url', enclosure.get('url').replace('.dmg', '.zip')),
                                     ('length', '124'), (f'{{{SPARKLE_NS}}}version', '15')]:
                old = enclosure.get(attribute)
                enclosure.set(attribute, value)
                XML.ElementTree(rss).write(feed)
                with self.subTest(attribute=attribute), self.assertRaises(ValueError):
                    publish_update.verify_prepared_macos(source, manifest, 'Public notes')
                enclosure.set(attribute, old)

    def test_reject_incomplete_desktop_pair(self):
        del self.manifest['platforms']['linux-deb']
        with self.assertRaises(ValueError):
            installer_names(self.manifest)

    def test_require_fedora_rpm_alongside_deb(self):
        del self.manifest['platforms']['linux-rpm']
        with self.assertRaises(ValueError):
            installer_names(self.manifest)


if __name__ == '__main__':
    unittest.main()
