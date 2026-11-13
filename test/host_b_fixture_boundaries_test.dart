import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';

import 'support/bot_display_fixture.dart';
import 'support/bots_fixture.dart';
import 'support/profile_intelligence_fixture.dart';
import 'support/profile_voice_fixture.dart';
import 'support/voice_fixture.dart';

void main() {
  for (final operation in [
    ('GET', 'tools/toolsets/tts/unknown'),
    ('POST', 'tools/toolsets/tts/provider'),
    ('POST', 'config/schema'),
    ('GET', 'audio/speak'),
    ('POST', 'audio/elevenlabs/voices'),
  ]) {
    test('voice fixture rejects ${operation.$1} ${operation.$2}', () async {
      final fixture = ProfileVoiceFixture();
      await expectLater(
        fixture.send(
          operation.$1,
          operation.$2,
          {'profile': 'personal'},
          {'provider': 'Edge'},
        ),
        throwsStateError,
      );
    });
  }

  for (final operation in ['config.get', 'config.set']) {
    test('intelligence fixture rejects unknown keys for $operation', () async {
      final fixture = ProfileIntelligenceFixture();
      final gateway = fixture.gateway(
        WorkspaceScope(
          connectionId: 'fixture',
          connectionIdentity: 'fixture',
          profileName: 'personal',
        ),
      );
      addTearDown(gateway.close);
      await expectLater(
        gateway.call(operation, {
          'key': 'misspelled_reasoning',
          'value': 'high',
        }),
        throwsStateError,
      );
    });
  }

  test(
    'voice fixture cannot return audio owned by another recording',
    () async {
      final fixture = VoiceDeviceFixture();
      addTearDown(fixture.stream.close);
      await fixture.start('current', local: false, language: '');
      expect(await fixture.stop('retired'), isNull);
      expect(fixture.recording, 'current');
      expect(await fixture.stop('current'), [1, 2, 3]);
    },
  );

  test(
    'group state reports newest event sequence rather than page length',
    () async {
      final fixture = BotsFixture()..events.add({'seq': 10});
      final state = await fixture.read('atlas', 'groups.state', {
        'room_id': 'room-1',
      });
      expect(state['room']['latest_seq'], 10);
    },
  );

  test('new group messages follow the last seeded event sequence', () async {
    final fixture = BotsFixture()
      ..events.add({'seq': 10, 'event_id': 'existing'});
    final result = await fixture.command(
      'atlas',
      'groups.send',
      {
        'room_id': 'room-1',
        'event_id': 'new',
        'payload': {'text': 'Next message'},
      },
      () => true,
      () {},
    );
    expect(result['event']['seq'], 11);
  });

  for (final phase in [0, 1, 2]) {
    test('display peer rejects invalid client handshake phase $phase', () {
      final peer = DisplayPeer()..phase = phase;
      addTearDown(peer.client.close);
      expect(() => peer.accept(Uint8List.fromList([0])), throwsStateError);
      expect(peer.phase, phase, reason: 'An invalid handshake cannot advance');
    });
  }
}
