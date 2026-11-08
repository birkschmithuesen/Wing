import 'dart:async';

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
  Future<void> open(Map<String, Object> initial, {bool manual = false}) async {
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
