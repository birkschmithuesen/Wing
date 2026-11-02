"""External-share emulator observations and owned-lifecycle guards."""
import unittest
import subprocess
from unittest.mock import patch
import xml.etree.ElementTree as ET
import check_external_share as external
from check_external_share import (focused_window_component, camera_components,
                                  retire_owned_host, provider_released, Device,
                                  host_has_saved_stopped_state, PACKAGE, HELPER)


class ExternalShareFocusTest(unittest.TestCase):
    def test_api36_display_focus(self):
        dump = '''WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  mCurrentFocus=Window{a3e74f3 u0 com.android.camera2/com.android.camera.CaptureActivity}
  mFocusedApp=ActivityRecord{123 u0 com.tarkilhk.wing.notificationqa/.MainActivity t14}
WINDOW MANAGER WINDOWS (dumpsys window windows)
  Window #9 Window{a3e74f3 u0 com.android.camera2/com.android.camera.CaptureActivity}:
'''
        self.assertEqual(focused_window_component(dump),
                         'com.android.camera2/com.android.camera.CaptureActivity')

    def test_observed_system_anr_is_not_focused_camera(self):
        dump = '''  mCurrentFocus=Window{9ec1641 u0 Application Not Responding: com.android.systemui}
  mFocusedApp=ActivityRecord{63540988 u0 com.android.camera2/com.android.camera.CaptureActivity t14}
    mFocusedWindow=Window{9ec1641 u0 Application Not Responding: com.android.systemui}
'''
        self.assertIsNone(focused_window_component(dump))

    def test_windows_only_dump_is_insufficient(self):
        self.assertIsNone(focused_window_component(
            'Window #9 Window{a3e74f3 u0 com.android.camera2/com.android.camera.CaptureActivity}:'))

    def test_null_focus_does_not_consume_next_line(self):
        self.assertIsNone(focused_window_component(
            '  mCurrentFocus=null\n  mFocusedApp=ActivityRecord{123 u0 com.android.camera2/.Camera t14}\n'))

    def test_short_activity_component(self):
        self.assertEqual(focused_window_component(
            '  mCurrentFocus=Window{123 u0 com.android.camera2/.Camera}\n'),
            'com.android.camera2/.Camera')


class ControlledCameraResolverTest(unittest.TestCase):
    def test_components_accept_real_brief_indentation_and_components_output(self):
        self.assertEqual(camera_components('2 activities found:\n'
            '  Activity #0:\n    priority=0 preferredOrder=0 match=0x108000\n'
            '    com.android.camera2/com.android.camera.CaptureActivity\n'
            'com.tarkilhk.wing.shareqa.fixture/.ControlledCameraActivity\n'), {
            'com.android.camera2/com.android.camera.CaptureActivity',
            'com.tarkilhk.wing.shareqa.fixture/.ControlledCameraActivity'})

    def test_headers_and_unresolved_components_are_not_handlers(self):
        self.assertEqual(camera_components('No activities found\nActivity #0:\n'), set())


class OwnedHostRetirementTest(unittest.TestCase):
    def test_actual_saved_stopped_owned_record_is_required(self):
        owned = ('    * Hist  #0: ActivityRecord{74383760 u0 '
                 + PACKAGE + '/com.tarkilhk.wing.MainActivity t52}\n'
                 '      mHaveState=true mIcicle=Bundle[mParcelledData.dataSize=784]\n'
                 '      state=STOPPED delayedResume=false finishing=false\n')
        camera = ('    * Hist  #1: ActivityRecord{123 u0 ' + HELPER
                  + '/.ControlledCameraActivity t52}\n'
                  '      mHaveState=false mIcicle=null\n      state=RESUMED\n')
        self.assertTrue(host_has_saved_stopped_state(camera + owned))
        for invalid in [owned.replace('STOPPED', 'PAUSED'),
                        owned.replace('true mIcicle=Bundle[mParcelledData.dataSize=784]',
                                      'false mIcicle=null'),
                        owned.replace(PACKAGE, HELPER),
                        owned + owned,
                        owned.replace('u0 ', 'u10 '),
                        owned.replace('com.tarkilhk.wing.MainActivity', 'OtherActivity'),
                        owned.replace('mHaveState=true mIcicle=Bundle[mParcelledData.dataSize=784]',
                                      'mHaveState=true mIcicle=null')]:
            with self.subTest(invalid=invalid):
                self.assertFalse(host_has_saved_stopped_state(invalid))

    def test_only_verified_qa_main_pid_is_killed_from_its_own_uid(self):
        class Fake:
            def __init__(self): self.calls = []
            def shell(self, *args):
                self.calls.append(args)
                return PACKAGE + '\x00'
        device = Fake()
        retire_owned_host(device, '1234')
        self.assertEqual(device.calls, [
            ('run-as', PACKAGE, 'cat', '/proc/1234/cmdline'),
            ('run-as', PACKAGE, 'kill', '-9', '1234'),
        ])

    def test_pid_and_process_identity_fail_before_kill(self):
        class Fake:
            def shell(self, *args):
                assert 'kill' not in args
                return 'unrelated.process\x00'
        for pid in ['1234', '-1', '0', '12 34', '12;34', '']:
            with self.subTest(pid=pid), self.assertRaises(ValueError):
                retire_owned_host(Fake(), pid)

    def test_missing_pid_is_expected_but_adb_errors_are_not_swallowed(self):
        class Fake(Device):
            def __init__(self, code, stderr=b''):
                self.code, self.stderr = code, stderr
            def shell(self, *args):
                raise subprocess.CalledProcessError(
                    self.code, args, output=b'', stderr=self.stderr)
        self.assertEqual(Fake(1).host_pid(), '')
        for device in [Fake(2), Fake(1, b'adb error')]:
            with self.assertRaises(subprocess.CalledProcessError):
                device.host_pid()

    def test_manifest_probe_wakes_provider_before_late_return_observation(self):
        class Frozen:
            def __init__(self): self.awake = False
            def shell(self, *args):
                assert args == ('am', 'broadcast', '-n', HELPER + '/.CameraCommandReceiver',
                                '-a', HELPER + '.PROBE')
                self.awake = True
            def preferences(self, package, name):
                assert self.awake and package == HELPER and name == 'probe'
                return {'released': '2'}
        self.assertTrue(provider_released(Frozen(), 1))
        self.assertFalse(provider_released(Frozen(), 2))


class PreferenceObservationTest(unittest.TestCase):
    def device(self, observations, *, exists=True):
        device = Device('emulator-5562')
        self.enterContext(patch.object(device, 'private_exists', return_value=exists))
        read = self.enterContext(patch.object(device, 'private_read', side_effect=observations))
        clock = [0.0]
        self.enterContext(patch.object(external.time, 'monotonic', side_effect=lambda: clock[0]))
        self.enterContext(patch.object(external.time, 'sleep', side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)))
        return device, read, clock

    def test_partial_write_is_observed_until_complete_before_returning_state(self):
        device, read, _ = self.device([
            b'', b'<map><string name="pending_name">qa-owned',
            b'<map><string name="pending_name">qa-owned.json</string><int name="saved_bytes" value="12" /></map>',
        ])
        self.assertEqual(device.preferences(HELPER, 'backup_save'),
                         {'pending_name': 'qa-owned.json', 'saved_bytes': '12'})
        self.assertEqual(read.call_count, 3)
        self.assertTrue(all(call.args == (HELPER, 'shared_prefs/backup_save.xml')
                            for call in read.call_args_list))

    def test_persistent_malformed_state_fails_at_observation_deadline(self):
        device, read, clock = self.device([b'<map>'] * 60)
        with self.assertRaises(ET.ParseError):
            device.preferences(HELPER, 'backup_save')
        self.assertEqual(clock[0], 5)
        self.assertGreater(read.call_count, 1)

    def test_transport_failure_is_not_retried_or_replaced_with_empty_state(self):
        error = subprocess.CalledProcessError(1, ['adb'], stderr=b'device offline')
        device, read, clock = self.device([error])
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            device.preferences(HELPER, 'backup_save')
        self.assertIs(raised.exception, error)
        self.assertEqual(read.call_count, 1)
        self.assertEqual(clock[0], 0)

    def test_absent_preferences_are_distinct_from_an_unfinished_file(self):
        device, read, _ = self.device([], exists=False)
        self.assertEqual(device.preferences(HELPER, 'backup_save'), {})
        read.assert_not_called()

    def test_complete_empty_map_is_a_valid_observation(self):
        device, read, clock = self.device([b'<map />'])
        self.assertEqual(device.preferences(HELPER, 'backup_save'), {})
        self.assertEqual(read.call_count, 1)
        self.assertEqual(clock[0], 0)


if __name__ == '__main__':
    unittest.main()
