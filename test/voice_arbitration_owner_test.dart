import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/controllers/voice_output_controller.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/voice_processing_settings.dart';

import 'support/voice_fixture.dart';

final target = ProfileSessionKey(
  WorkspaceScope(
    connectionId: 'voice',
    connectionIdentity: 'captured',
    profileName: 'personal',
  ),
  'chat',
);
const draft = VoiceDraft(text: 'Alpha', selectionStart: 5, selectionEnd: 5);

void main() {
  test(
    'retiring dictation during held playback stop prevents native capture',
    () async {
      final device = VoiceDeviceFixture();
      final recorder = VoiceInputController(device: device);
      final stopped = Completer<void>();
      addTearDown(recorder.dispose);
      addTearDown(device.stream.close);
      final pending = recorder.dictate(
        target: target,
        draft: draft,
        settings: () => const LocalVoiceInputSettings(language: ''),
        stopPlayback: () => stopped.future,
        admitsTarget: (_) => true,
        admitPresentation: () => true,
        createRemote: (_) =>
            throw StateError('No remote input for local recording'),
        applyDraft: (_) async => fail('A retired recording cannot edit'),
        onApplied: (_) => fail('A retired recording cannot present'),
        onNotice: (_) => fail('Retirement is not a failure'),
      );
      recorder.retainTarget(null);
      stopped.complete();
      await pending;
      expect(device.calls, isEmpty);
      expect(recorder.active, isFalse);
    },
  );

  test(
    'retiring playback during held recorder cancellation prevents speech',
    () async {
      final device = VoiceDeviceFixture();
      final player = VoiceOutputController(device);
      final cancelled = Completer<void>();
      addTearDown(player.dispose);
      addTearDown(device.stream.close);
      final pending = player.readAloud(
        reply: VoiceReply(key: VoiceReplyKey(target, 'reply'), text: 'Hello'),
        settings: () => const LocalVoiceOutputSettings(
          voice: '',
          rate: AppVoiceRate.normal,
        ),
        cancelDictation: () => cancelled.future,
        admitsTarget: (_) => true,
        admitPresentation: () => true,
        createRemote: (_) => RemoteVoiceFixture(),
        onNotice: (_) => fail('Retirement is not a failure'),
      );
      player.retainTarget(null);
      cancelled.complete();
      await pending;
      expect(device.calls, isEmpty);
      expect(player.owner, isNull);
    },
  );

  test(
    'a completed admitted dictation applies one captured original',
    () async {
      final device = VoiceDeviceFixture();
      final recorder = VoiceInputController(device: device);
      addTearDown(recorder.dispose);
      addTearDown(device.stream.close);
      var writes = 0;
      VoiceDraft? presented;
      await recorder.dictate(
        target: target,
        draft: draft,
        settings: () => const LocalVoiceInputSettings(language: ''),
        stopPlayback: () async {},
        admitsTarget: (_) => true,
        admitPresentation: () => true,
        createRemote: (_) => RemoteVoiceFixture(),
        applyDraft: (text) {
          writes++;
          expect(text, 'Alpha spoken');
          return Future.value();
        },
        onApplied: (value) => presented = value,
        onNotice: (_) => fail('Admitted completion has no notice'),
      );
      device.stream.add({
        'id': device.recording,
        'text': 'spoken',
        'final': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      expect(presented!.text, 'Alpha spoken');
      expect(presented!.selectionEnd, 12);
      expect(recorder.active, isFalse);
    },
  );

  test(
    'read-aloud toggles only the captured reply and preserves its profile',
    () async {
      final device = VoiceDeviceFixture()..playbackDelay = Completer<void>();
      final player = VoiceOutputController(device);
      final remote = RemoteVoiceFixture();
      addTearDown(player.dispose);
      addTearDown(device.stream.close);
      final reply = VoiceReply(
        key: VoiceReplyKey(target, 'reply'),
        text: 'Hello',
      );
      var cancellations = 0;
      Future<void> read() => player.readAloud(
        reply: reply,
        settings: () => const LocalVoiceOutputSettings(
          voice: '',
          rate: AppVoiceRate.normal,
        ),
        cancelDictation: () async {
          cancellations++;
        },
        admitsTarget: (_) => true,
        admitPresentation: () => true,
        createRemote: (_) => remote,
        onNotice: (_) => fail('Valid playback has no notice'),
      );
      final first = read();
      await Future<void>.delayed(Duration.zero);
      expect(player.owner, reply.key);
      expect((player.owner as VoiceReplyKey).session, target);
      await read();
      expect(player.owner, isNull);
      expect(cancellations, 1);
      expect(
        device.calls.where((value) => value == 'stopPlayback'),
        hasLength(1),
      );
      device.playbackDelay!.complete();
      await first;
      expect(remote.closed, isFalse);
    },
  );
}
