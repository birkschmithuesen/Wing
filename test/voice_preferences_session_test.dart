import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/voice_preferences_session.dart';

import 'support/voice_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late AppPreferences owner;
  late VoiceDeviceFixture device;
  late VoicePreferencesSession session;
  Future<void> open(
    Map<String, Object> initial, {
    bool manual = false,
    Future<Uint8List> Function(String)? loadSample,
  }) async {
    SharedPreferences.resetStatic();
    storage = _Storage(initial);
    SharedPreferencesStorePlatform.instance = storage;
    owner = AppPreferences(await SharedPreferences.getInstance());
    device = VoiceDeviceFixture();
    if (manual) {
      device.capabilitiesValue = const AndroidVoiceCapabilities(
        recognitionAvailable: true,
        voices: [],
      );
    }
    session = VoicePreferencesSession(
      preferences: owner,
      device: device,
      hermesProfileLabel: null,
      openHermesSettings: null,
      loadSample: loadSample ?? (_) async => Uint8List.fromList([1, 2, 3]),
    );
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() async {
    session.dispose();
    owner.dispose();
    await device.stream.close();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'subscription preview loads selected asset without saving or using TTS',
    () async {
      final assets = <String>[];
      await open(
        {'voice.live_subscription_voice': 'vale'},
        loadSample: (asset) async {
          assets.add(asset);
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      device.playbackDelay = Completer<void>();
      session.current.livePreview!();
      expect(session.current.livePreviewPreparing, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(assets, ['assets/voice_samples/subscription/vale.m4a']);
      expect(device.calls, ['play']);
      device.stream.add({'id': device.playing, 'playing': true});
      expect(session.current.livePreviewPreparing, isFalse);
      expect(session.current.livePreviewActive, isTrue);
      device.playbackDelay!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(session.current.livePreviewActive, isFalse);
      expect(storage.writes, isEmpty);
      await session.current.liveMode.choose!(LiveVoiceMode.api);
      expect(session.current.livePreview, isNull);
    },
  );

  for (final departure in ['stop', 'voice', 'background', 'close']) {
    test(
      '$departure retires a loading sample before it reaches the speaker',
      () async {
        final load = Completer<Uint8List>();
        await open({}, loadSample: (_) => load.future);
        session.current.livePreview!();
        expect(session.current.livePreviewPreparing, isTrue);
        switch (departure) {
          case 'stop':
            session.current.livePreview!();
          case 'voice':
            await session.current.liveVoice!.choose!('breeze');
          case 'background':
            session.lifecycle(AppLifecycleState.paused);
          case 'close':
            session.dispose();
        }
        load.complete(Uint8List.fromList([1, 2, 3]));
        await Future<void>.delayed(Duration.zero);
        expect(device.calls, isNot(contains('play')));
      },
    );
  }

  test(
    'Android preview replaces live playback and ignores its late completion',
    () async {
      await open({});
      final oldPlayback = Completer<void>();
      device.playbackDelay = oldPlayback;
      session.current.livePreview!();
      await Future<void>.delayed(Duration.zero);
      final newPlayback = Completer<void>();
      device.playbackDelay = newPlayback;
      session.current.preview!();
      await Future<void>.delayed(Duration.zero);
      expect(device.calls, ['play', 'stopPlayback', 'speak']);
      oldPlayback.complete();
      await Future<void>.delayed(Duration.zero);
      expect(session.current.previewActive, isTrue);
      expect(session.current.livePreviewActive, isFalse);
      newPlayback.complete();
      await Future<void>.delayed(Duration.zero);
      expect(session.current.previewActive, isFalse);
    },
  );

  test(
    'failed sample load can be retried without changing preferences',
    () async {
      var fail = true;
      await open(
        {},
        loadSample: (_) async {
          if (fail) {
            throw StateError(
              'Could not load this voice preview. Please try again.',
            );
          }
          return Uint8List.fromList([1]);
        },
      );
      session.current.livePreview!();
      await Future<void>.delayed(Duration.zero);
      expect(session.current.livePreviewError, contains('Could not load'));
      expect(session.current.previewError, isNull);
      fail = false;
      session.current.livePreview!();
      await Future<void>.delayed(Duration.zero);
      expect(session.current.livePreviewError, isNull);
      expect(device.calls, ['play']);
      expect(storage.writes, isEmpty);
    },
  );

  test(
    'a preference command accepted before route closure finishes in the shared owner',
    () async {
      await open({});
      storage.hold = true;
      final save = session.current.output.choose!(AppVoiceProcessing.hermes);
      await storage.started.future;
      session.dispose();
      storage.release.complete();
      expect(await save, isTrue);
      expect(owner.current.values.voiceOutput, AppVoiceProcessing.hermes);
      expect((await storage.getAll())['flutter.voice.output'], 'hermes');
      expect(storage.writes, ['voice.output=hermes']);
    },
  );

  test('GPT-Live save stays bound to its mode while settings change', () async {
    await open({});
    storage.hold = true;
    final save = session.current.liveVoice!.choose!('breeze');
    await storage.started.future;
    expect(session.current.liveVoice!.busy, isTrue);
    final modeChange = owner.setLiveVoiceMode(LiveVoiceMode.api);
    storage.release.complete();
    expect(await save, isTrue);
    await modeChange;
    expect(session.current.liveVoice!.selected, 'marin');
    expect(owner.current.liveSubscriptionVoice.selected, 'breeze');
  });

  test(
    'invalid inactive local fields remain repairable without blocking valid Hermes processing',
    () async {
      await open({
        'voice.input': 'hermes',
        'voice.output': 'hermes',
        AppPreferenceField.voiceLanguage.storageKey: 7,
        AppPreferenceField.voiceRate.storageKey: 'invalid',
      });
      expect(owner.current.voiceInputSettings, isA<HermesVoiceInputSettings>());
      expect(
        owner.current.voiceOutputSettings,
        isA<HermesVoiceOutputSettings>(),
      );
      expect(session.current.showLanguage, isTrue);
      expect(session.current.showLocalOutput, isTrue);
      expect(session.current.language.selected, isNull);
      expect(session.current.rate.selected, isNull);
      expect(session.current.preview, isNull);
      expect(await session.current.language.choose!('fr-FR'), isTrue);
      expect(owner.current.voiceInputSettings, isA<HermesVoiceInputSettings>());
      expect(owner.current.voiceRate.selected, isNull);
      expect(storage.writes, [
        '${AppPreferenceField.voiceLanguage.storageKey}=fr-FR',
      ]);
    },
  );

  test(
    'manual validation starts no save and unavailable installed choice stays explicit',
    () async {
      await open({
        AppPreferenceField.voiceLanguage.storageKey: 'zz-ZZ',
        AppPreferenceField.voice.storageKey: 'removed',
      }, manual: true);
      expect(
        await session.current.saveManualLanguage!('invalid language!'),
        isFalse,
      );
      expect(
        session.current.language.error,
        'Enter a language tag such as en-US.',
      );
      expect(storage.writes, isEmpty);
      expect(session.current.voices.last, (
        value: 'removed',
        label: 'removed · unavailable',
      ));
      expect(await session.current.saveManualLanguage!(' fr-FR '), isTrue);
      expect(owner.current.values.voiceLanguage, 'fr-FR');
      expect(storage.writes, [
        '${AppPreferenceField.voiceLanguage.storageKey}=fr-FR',
      ]);
    },
  );
}

class _Storage extends InMemorySharedPreferencesStore {
  _Storage(Map<String, Object> initial)
    : super.withData({
        for (final entry in initial.entries)
          'flutter.${entry.key}': entry.value,
      });
  bool hold = false;
  final started = Completer<void>();
  final release = Completer<void>();
  final writes = <String>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add('${key.substring(8)}=$value');
    if (hold) {
      hold = false;
      started.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}
