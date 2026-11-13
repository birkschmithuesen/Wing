"""Offline checks for reproducible native inputs and content-free metric exports."""
import unittest
from unittest.mock import Mock, patch

import replay_workspace as replay


class ReplayChecks(unittest.TestCase):
    def test_native_deadlines_do_not_accumulate_transport_latency(self):
        clock = [0]
        def sleep(seconds): clock[0] += round(seconds * 1e9)
        def tap(*args): clock[0] += 4000000
        with patch.object(replay.time, 'monotonic_ns', side_effect=lambda: clock[0]), \
             patch.object(replay.time, 'sleep', side_effect=sleep), \
             patch.object(replay, 'guard'), patch.object(replay, 'adb', side_effect=tap) as adb:
            report = replay.native_typing(Mock(), 'swiftkey')
        self.assertEqual(adb.call_count, 60)
        self.assertEqual(report['achievedUs'][-1], 15004000)
        self.assertEqual(report['maxCompletionLatenessUs'], 4000)
        self.assertTrue(report['scheduleValid'])

    def test_lost_foreground_stops_before_first_key(self):
        with patch.object(replay.time, 'sleep'), patch.object(replay, 'guard', side_effect=ValueError), \
             patch.object(replay, 'adb') as adb:
            with self.assertRaises(ValueError): replay.native_typing(Mock(), 'swiftkey')
        adb.assert_not_called()

    def test_source_and_draft_are_hashed_not_exported(self):
        result = replay.export_replay({'source':'PRIVATE TEXT', 'initialSource':'INITIAL',
                                      'draft':'PRIVATE DRAFT', 'startUs':100, 'endUs':200,
                                      'frames':[{'startUs':110,'buildUs':12,'rasterStartUs':123,'rasterUs':5}]})
        self.assertNotIn('PRIVATE', str(result))
        self.assertNotIn('source', result)
        self.assertNotIn('draft', result)
        self.assertEqual(result['draftCharacters'], 13)
        self.assertEqual(len(result['sourceSha256']), 64)
        self.assertEqual(result['frameBuildStartUs'], [110])

    def test_emulator_mode_rejects_phone_before_any_connection(self):
        with patch.object(replay, 'WingPerfClient') as client:
            with self.assertRaises(ValueError):
                replay.capture('10.30.1.2:12345', 'control-1', 'unused', 'unused', 'emulator')
            client.assert_not_called()

    def test_wrong_foreground_is_not_accepted(self):
        with patch.object(replay, 'adb', return_value=b'mCurrentFocus=Window{other.app/Main}'):
            with self.assertRaises(ValueError): replay.guard(Mock())

    def test_keyboard_preflight_requires_ready_empty_focused_composer_and_visible_ime(self):
        ready = {'prepared': True, 'keyboard': True, 'composerFocused': True, 'draft': ''}
        def answer(_client, *args):
            if args[1:3] == ('settings', 'get'):
                return b'com.touchtype.swiftkey.beta/com.touchtype.KeyboardService'
            return b'mInputShown=true\n'
        with patch.object(replay, 'guard'), \
             patch.object(replay, 'rpc', return_value=ready) as rpc, \
             patch.object(replay, 'adb', side_effect=answer) as adb:
            replay.keyboard_preflight(Mock(), 'swiftkey')
        rpc.assert_called_once()
        self.assertEqual(adb.call_args.args[1:], ('shell', 'dumpsys', 'input_method'))

    def test_keyboard_preflight_rejects_invalid_ready_states_and_hidden_ime(self):
        ready = {'prepared': True, 'keyboard': True, 'composerFocused': True, 'draft': ''}
        invalid_states = [
            dict(ready, draft='x'),
            dict(ready, composerFocused=False),
            dict(ready, prepared=False),
            dict(ready, keyboard=False),
        ]
        for state in invalid_states:
            def answer(_client, *args):
                if args[1:3] == ('settings', 'get'):
                    return b'com.touchtype.swiftkey.beta/com.touchtype.KeyboardService'
                return b'mInputShown=true\n'
            with self.subTest(state=state), \
                 patch.object(replay, 'guard'), \
                 patch.object(replay, 'rpc', return_value=state), \
                 patch.object(replay, 'adb', side_effect=answer):
                with self.assertRaises(ValueError): replay.keyboard_preflight(Mock(), 'swiftkey')

        def hidden_ime(_client, *args):
            if args[1:3] == ('settings', 'get'):
                return b'com.touchtype.swiftkey.beta/com.touchtype.KeyboardService'
            return b'mInputShown=false\n'
        with patch.object(replay, 'guard'), \
             patch.object(replay, 'rpc', return_value=ready), \
             patch.object(replay, 'adb', side_effect=hidden_ime):
            with self.assertRaises(ValueError): replay.keyboard_preflight(Mock(), 'swiftkey')

    def test_keyboard_preflight_rejects_wrong_phone_ime(self):
        with patch.object(replay, 'guard'), \
             patch.object(replay, 'rpc') as rpc, \
             patch.object(replay, 'adb', return_value=b'other.keyboard/Service'):
            with self.assertRaises(ValueError): replay.keyboard_preflight(Mock(), 'swiftkey')
        rpc.assert_not_called()


if __name__ == '__main__':
    unittest.main()
