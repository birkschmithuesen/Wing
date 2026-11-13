import 'package:wing/core/models/settings_edit.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/profile_voice_controller.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_voice_repository.dart';
import 'package:wing/core/services/voice_sample.dart';
import 'support/profile_voice_fixture.dart';
import 'support/voice_fixture.dart';

void main() {
  ProfileVoiceController controller(
    ProfileVoiceFixture f, {
    ProfileVoiceRepository? repository,
  }) {
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    return ProfileVoiceController(
      repository ?? ProfileVoiceRepository(f.server.profile('personal')),
      device: device,
    );
  }

  test(
    'Nous retains its route while reading and saving OpenAI voice settings',
    () async {
      final f = ProfileVoiceFixture();
      setSetting(f.configs['personal']!, 'tts.provider', 'nous');
      final repository = ProfileVoiceRepository(f.server.profile('personal'));
      final c = controller(f, repository: repository);
      await c.load();
      expect(c.state.settings!.provider, 'nous');
      expect(c.state.settings!.key, 'tts.openai.voice');
      expect(c.state.settings!.voice, 'alloy');
      await c.select('nova');
      expect(c.state.error, isNull);
      expect(setting(f.configs['personal']!, 'tts.provider'), 'nous');
      expect(setting(f.configs['personal']!, 'tts.openai.voice'), 'nova');
      expect(setting(f.configs['personal']!, 'tts.nous'), isNull);
      // A direct OpenAI selection must invalidate a sample prepared for Nous.
      setSetting(f.configs['personal']!, 'tts.provider', 'openai');
      await expectLater(
        repository.verify(c.state.settings!),
        throwsA(isA<AdministrationFailure>()),
      );
      c.dispose();
    },
  );

  test('rapid choices serialize writes and newest selection wins', () async {
    final f = ProfileVoiceFixture()
      ..writeGate = Completer()
      ..putStarted = Completer();
    final c = controller(f);
    await c.load();
    final before = c.state;
    expect(() => before.choices.clear(), throwsUnsupportedError);
    await c.select('en-US-AriaNeural');
    final first = c.select('en-US-JennyNeural');
    await f.putStarted!.future;
    final second = c.select('en-US-BrianNeural');
    final third = c.select('en-GB-SoniaNeural');
    expect(c.state.saving, isTrue);
    expect(f.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
    f.writeGate!.complete();
    await Future.wait([first, second, third]);
    final writes = f.requests.where((r) => r.$1 == 'PUT').toList();
    expect(writes, hasLength(2));
    expect(writes.last.$4, {
      'profile': 'personal',
      'config': {
        'tts': {
          'edge': {'voice': 'en-GB-SoniaNeural'},
        },
      },
    });
    expect(writes.every((r) => r.$3['profile'] == 'personal'), isTrue);
    expect(c.state.settings!.voice, 'en-GB-SoniaNeural');
    expect(before.settings!.voice, 'en-US-AriaNeural');
    expect(c.state.selected, c.state.settings!.voice);
    expect(setting(f.configs['personal']!, 'tts.edge.speed'), 1.2);
    expect(f.configs['personal']!['unrelated'], {'keep': true});
    expect(f.configs['work']!['tts'], isNull);
    await c.select('en-US-GuyNeural');
    expect(c.state.settings!.voice, 'en-US-GuyNeural');
    c.dispose();
  });

  test(
    'rejected and unconfirmed writes retain confirmed voice until refresh',
    () async {
      for (final reject in [true, false]) {
        final f = ProfileVoiceFixture()
          ..reject = reject
          ..ignoreSave = !reject;
        final c = controller(f);
        await c.load();
        await c.select('en-US-JennyNeural');
        expect(c.state.selected, 'en-US-AriaNeural');
        expect(c.state.fresh, isFalse);
        expect(c.state.error, isNotNull);
        expect(
          c.state.voiceAcknowledged,
          reject ? isNull : 'en-US-JennyNeural',
        );
        final count = f.requests.length;
        await c.select('en-US-GuyNeural');
        expect(f.requests.length, count);
        f.reject = false;
        f.ignoreSave = false;
        await c.load();
        await c.select('en-US-GuyNeural');
        expect(c.state.settings!.voice, 'en-US-GuyNeural');
        c.dispose();
      }
    },
  );

  test('provider and voice conflicts cannot overwrite another edit', () async {
    for (final key in ['tts.provider', 'tts.edge.voice']) {
      final f = ProfileVoiceFixture();
      final c = controller(f);
      await c.load();
      setSetting(f.configs['personal']!, key, 'changed');
      await c.select('en-US-JennyNeural');
      expect(c.state.error, contains('changed elsewhere'));
      expect(f.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      c.dispose();
    }
  });

  test(
    'ElevenLabs loads real IDs; missing catalogue is distinct from empty',
    () async {
      final f = ProfileVoiceFixture();
      setSetting(f.configs['personal']!, 'tts.provider', 'elevenlabs');
      final c = controller(f);
      await c.load();
      expect(c.state.choices.map((v) => v.id), ['custom-a', 'custom-b']);
      expect(
        f.requests.singleWhere((r) => r.$2 == 'audio/elevenlabs/voices').$3,
        {'profile': 'personal'},
      );
      await c.select('custom-b');
      expect(
        setting(f.configs['personal']!, 'tts.elevenlabs.voice_id'),
        'custom-b',
      );
      f.catalogue = {'available': false, 'voices': []};
      await c.load();
      expect(c.state.catalogueError, isNotNull);
      expect(c.state.settings!.voice, 'custom-b');
      f.catalogue = {
        'available': true,
        'voices': [
          {'voice_id': 'bad'},
        ],
      };
      await c.load();
      expect(c.state.catalogueError, isNotNull);
      c.dispose();
    },
  );

  test(
    'test speech uses only stock text request and never changes settings',
    () async {
      final f = ProfileVoiceFixture();
      final repository = ProfileVoiceRepository(f.server.profile('personal'));
      final c = controller(f, repository: repository);
      await c.load();
      final speech = repository.speech(
        c.state.settings!,
        canDispatch: () => c.state.fresh,
      );
      expect(await speech.synthesize(voiceSampleText), [1, 2, 3]);
      final request = f.requests.singleWhere((r) => r.$2 == 'audio/speak');
      expect(request.$3, {'profile': 'personal'});
      expect(request.$4, {'text': voiceSampleText});
      expect(f.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      speech.close();
      c.dispose();
    },
  );

  test(
    'settings changes during synthesis discard incorrectly labelled audio',
    () async {
      final f = ProfileVoiceFixture()..audioGate = Completer();
      final repository = ProfileVoiceRepository(f.server.profile('personal'));
      final c = controller(f, repository: repository);
      await c.load();
      final speech = repository.speech(
        c.state.settings!,
        canDispatch: () => c.state.fresh,
      );
      final request = speech.synthesize(voiceSampleText);
      await Future<void>.delayed(Duration.zero);
      setSetting(f.configs['personal']!, 'tts.edge.voice', 'changed');
      f.audioGate!.complete(f.audio);
      await expectLater(
        request,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('changed elsewhere'),
          ),
        ),
      );
      speech.close();
      c.dispose();
    },
  );

  test('leaving an editor preserves the final queued autosave', () async {
    final f = ProfileVoiceFixture()
      ..writeGate = Completer()
      ..putStarted = Completer();
    final c = controller(f);
    await c.load();
    final first = c.select('en-US-JennyNeural');
    await f.putStarted!.future;
    final last = c.select('en-US-GuyNeural');
    c.dispose();
    f.server.close();
    f.writeGate!.complete();
    await Future.wait([first, last]);
    expect(
      setting(f.configs['personal']!, 'tts.edge.voice'),
      'en-US-GuyNeural',
    );
  });
  test(
    'retired provider editor cannot dispatch after held owned admission',
    () async {
      final f = ProfileVoiceFixture();
      final c = controller(f);
      await c.load();
      final admission = Completer<void>(), release = Completer<void>();
      var writes = 0;
      f.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            admission.complete();
            await release.future;
            if (!canDispatch()) throw StateError('Retired before dispatch');
            writes++;
            onDispatched();
            return f.send(method, path, query, body);
          };
      final save = c.selectProvider('ElevenLabs');
      await admission.future;
      c.dispose();
      release.complete();
      await save;
      expect(writes, 0);
      expect(setting(f.configs['personal']!, 'tts.provider'), 'edge');
      expect(f.requests.where((request) => request.$1 != 'GET'), isEmpty);
    },
  );

  test(
    'listener retirement stops an unsent read without disposing inside notification',
    () async {
      final f = ProfileVoiceFixture();
      final c = controller(f);
      c.addListener(c.dispose);
      await c.load();
      expect(f.requests, isEmpty);
      c.dispose();
    },
  );
}
