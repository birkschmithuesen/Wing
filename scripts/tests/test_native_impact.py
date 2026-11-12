import tempfile
from pathlib import Path
import unittest

from scripts import native_impact as impact


class NativeImpact(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def test_shared_scenario_and_production_imports_select_their_native_consumers(self):
        self.write('integration_test/administration_native_test.dart',
                   "import '../test/support/editor.dart';")
        self.write('test/support/editor.dart', "export 'package:wing/editor.dart';")
        self.write('lib/editor.dart', "part 'editor_state.dart';")
        self.write('lib/editor_state.dart', '')
        for changed in ('test/support/editor.dart', 'lib/editor.dart', 'lib/editor_state.dart'):
            self.assertEqual(set(impact.select(self.root, [changed])), {'administration'})

    def test_driver_named_suite_and_python_helper_select_the_consumer(self):
        self.write('scripts/test_native_bots.py',
                   'from tools.qa import gestures\nTARGET = "integration_test/bots_native_test.dart"')
        self.write('tools/qa/gestures.py', '')
        self.write('integration_test/bots_native_test.dart', '')
        for changed in ('tools/qa/gestures.py', 'integration_test/bots_native_test.dart'):
            self.assertEqual(set(impact.select(self.root, [changed])), {'bots'})

    def test_deleted_import_and_native_helper_remain_affected(self):
        self.write('integration_test/administration_native_test.dart',
                   "import '../test/support/deleted.dart';")
        self.assertEqual(set(impact.select(self.root, ['test/support/deleted.dart'])), {'administration'})
        self.write('integration_test/fixtures/recents_touch/NativeRecentsTouch.java', '')
        self.assertEqual(set(impact.select(self.root,
            ['integration_test/fixtures/recents_touch/NativeRecentsTouch.java'])),
            {'recents', 'recents-code', 'recents-events', 'recents-momentum'})

    def test_unknown_executable_build_dependency_and_workflow_changes_run_all(self):
        for name in ('lib/new.dart', 'assets/example.md', 'android/app/build.gradle.kts', 'pubspec.lock',
                     'scripts/test_nightly_native.py', 'tools/qa/run_notification_gate.py',
                     '.github/workflows/native-impact.yml'):
            self.assertEqual(set(impact.select(self.root, [name])), set(impact.FAMILIES))

    def test_only_known_documentation_can_omit_native_work(self):
        self.assertEqual(impact.select(self.root, ['README.md', 'docs/features/conversation.md']), {})
        self.assertEqual(impact.select(self.root, []), {})

    def test_missing_or_invalid_base_runs_every_family(self):
        for reference in ('', '0' * 40, 'not-a-ref'):
            self.assertEqual(set(impact.plan(self.root, reference)['families']), set(impact.FAMILIES))

    def test_current_catalog_has_real_inputs_and_affected_failure_families(self):
        root = Path(__file__).resolve().parents[2]
        for family, seeds in impact.FAMILY_INPUTS.items():
            for seed in seeds:
                self.assertTrue((root / seed).exists(), (family, seed))
        changed = ['integration_test/recent_conversation_native_test.dart',
                   'test/support/upstream_capabilities_scenarios.dart',
                   'integration_test/background_monitoring_device.dart']
        selected = impact.select(root, changed)
        self.assertTrue({'recents', 'recents-code', 'recents-events', 'recents-momentum',
                         'administration', 'background'}.issubset(selected))
        # The nightly runner imports these helpers before selecting a family;
        # they must not look like changes affecting only the driver's own suite.
        for shared in ('scripts/test_native_bots.py', 'scripts/test_journeys.py',
                       'scripts/test_vanilla_hermes.py'):
            self.assertEqual(set(impact.select(root, [shared])), set(impact.FAMILIES))


if __name__ == '__main__':
    unittest.main()
