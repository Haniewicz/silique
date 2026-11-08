"""Regression checks for the protected default Windows installation.
Run with: python -m unittest discover -s tool/windows -p 'test_*.py'
These do not launch an installer, request UAC, or alter Defender.
"""
from pathlib import Path
import re
import unittest

SCRIPT = Path(__file__).with_name('silique.iss')


def setup_values():
    text = SCRIPT.read_text(encoding='utf-8')
    section = text.split('[Setup]', 1)[1].split('[Languages]', 1)[0]
    return {
        match.group(1).casefold(): match.group(2).strip()
        for match in re.finditer(r'^([A-Za-z]+)=(.*)$', section, re.MULTILINE)
    }


class ProtectedInstallationTests(unittest.TestCase):
    def test_default_install_is_protected_program_files(self):
        self.assertEqual(setup_values()['defaultdirname'], r'{autopf}\Silique')

    def test_installer_requires_admin_without_low_privilege_override(self):
        values = setup_values()
        self.assertEqual(values['privilegesrequired'], 'admin')
        self.assertNotIn('privilegesrequiredoverridesallowed', values)

    def test_upgrade_does_not_reuse_old_appdata_destination(self):
        self.assertEqual(setup_values().get('usepreviousappdir'), 'no')

    def test_installer_never_launches_the_application(self):
        # runasoriginaluser is not a de-elevation guarantee: when Setup was
        # started "as administrator" the post-install launch inherits the token.
        # Starting the notebook with an administrator token is never wanted.
        text = SCRIPT.read_text(encoding='utf-8')
        self.assertNotIn('postinstall', text)
        self.assertNotIn('runasoriginaluser', text)
        self.assertNotIn('runascurrentuser', text)

    def test_legacy_per_user_install_is_reported_and_never_deleted(self):
        text = SCRIPT.read_text(encoding='utf-8')
        self.assertIn('LegacyPerUserInstall', text)
        self.assertIn('WizardSilent', text)
        # Inform, do not touch: vaults, keys and the user's own shortcuts stay.
        self.assertNotIn('DelTree', text)
        self.assertNotIn('UninstallDelete', text)
        self.assertNotIn('InstallDelete', text)
        self.assertNotIn('DeleteFile', text)

    def test_installer_never_changes_defender_or_deletes_user_data(self):
        text = SCRIPT.read_text(encoding='utf-8')
        self.assertNotIn('[UninstallDelete]', text)
        self.assertNotIn('[InstallDelete]', text)
        self.assertNotIn('Add-MpPreference', text)
        self.assertNotIn('Set-MpPreference', text)
        self.assertNotIn('ExclusionProcess', text)


if __name__ == '__main__':
    unittest.main()
