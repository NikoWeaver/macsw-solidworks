"""Guard the team wizard's access key step without running the app (docs/team-admin.md)."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCES = PROJECT / 'macos/Bootstrap/Sources'
CORE = SOURCES / 'MacSWCore'
VIEWS = SOURCES / 'MacSWApp/Features/Bootstrap'


class TeamWizardAccessKeyTests(unittest.TestCase):
    def test_access_key_is_one_field_in_memory_only(self):
        view = (VIEWS / 'TeamSetupView.swift').read_text()
        self.assertIn('TextField("XXXX XXXX XXXX XXXX XXXX XXXX", text: $store.serialSolidWorks)', view)
        self.assertIn('AccessKey.check(store.serialSolidWorks)', view)
        for banned in ('@AppStorage', 'UserDefaults', '.write(', 'NSLog', 'print(', 'Logger'):
            self.assertNotIn(banned, view, banned)

    def test_other_fields_appear_only_when_the_config_shows_them(self):
        view = (VIEWS / 'TeamSetupView.swift').read_text()
        self.assertIn('if install.showOtherKeys {', view)
        self.assertIn('if install.showLicenseServer {', view)
        store = (CORE / 'Stores/TeamSetupStore.swift').read_text()
        self.assertIn('if !config.install.showLicenseServer { bootstrap.licenseMode = .unconfigured }', store)

    def test_finished_install_forgets_the_key(self):
        view = (VIEWS / 'BootstrapView.swift').read_text()
        self.assertIn('.onAppear { team.finish(store) }', view)
        store = (CORE / 'Stores/TeamSetupStore.swift').read_text()
        finish = store[store.index('public func finish('):]
        self.assertLess(finish.index('bootstrap.forgetSerials()'), finish.index('\n    }\n'))

    def test_access_key_page_says_the_retry_rule_before_install(self):
        # docs/spatialiop-fix.md: the window explains the fresh bottle before the install starts.
        for name in ('TeamSetupView.swift', 'BootstrapView.swift'):
            view = (VIEWS / name).read_text()
            note = view.index('if store.replacesFailedBottle {')
            self.assertIn('CoreInstallRetry.freshBottleNote', view[note:note + 200], name)
        view = (VIEWS / 'TeamSetupView.swift').read_text()
        self.assertLess(view.index('if store.replacesFailedBottle {'), view.index('Button("Install")'))


if __name__ == '__main__':
    unittest.main()
