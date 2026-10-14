import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/device_preference.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/widgets/voice_preferences_card.dart';
import 'support/voice_fixture.dart';

class _FailingPreferences extends Fake implements SharedPreferences {
  final values = <String, Object>{};
  bool failNext = true;
  @override
  Object? get(String key) => values[key];
  @override
  String? getString(String key) => values[key] as String?;
  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    final failed = failNext;
    failNext = false;
    return !failed;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('voice-settings-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('$path/${entry.value}').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
    }
  });
  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File(
        'build/voice-review/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'independent engines and Android voice settings survive reload',
    () async {
      final prefs = await SharedPreferences.getInstance();
      expect(VoicePreferences.read(prefs).input, VoiceInputRoute.local);
      expect(VoicePreferences.read(prefs).output, VoiceProcessing.local);
      await saveDevicePreference(prefs, VoicePreferences.inputKey, 'hermes');
      await saveDevicePreference(prefs, VoicePreferences.voiceKey, 'french');
      await saveDevicePreference(prefs, VoicePreferences.languageKey, 'fr-FR');
      await saveDevicePreference(prefs, VoicePreferences.rateKey, '0.8');
      await prefs.reload();
      final saved = VoicePreferences.read(prefs);
      expect(saved.input, VoiceInputRoute.hermes);
      expect(saved.output, VoiceProcessing.local);
      expect(saved.voice, 'french');
      expect(saved.language, 'fr-FR');
      expect(saved.rate, 0.8);
      expect(saved.autoSpeak, isFalse);
    },
  );

  test('spoken replies toggle persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoicePreferences.read(prefs).autoSpeak, isFalse);
    expect(VoicePreferences.keys, contains(VoicePreferences.autoSpeakKey));
    expect(VoicePreferences.accepts(VoicePreferences.autoSpeakKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.autoSpeakKey, 'off'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.autoSpeakKey, 'yes'), isFalse);
    await saveDevicePreference(prefs, VoicePreferences.autoSpeakKey, 'on');
    await prefs.reload();
    expect(VoicePreferences.read(prefs).autoSpeak, isTrue);
    await saveDevicePreference(prefs, VoicePreferences.autoSpeakKey, 'off');
    await prefs.reload();
    expect(VoicePreferences.read(prefs).autoSpeak, isFalse);
  });

  test('conversation mode toggle persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoicePreferences.read(prefs).conversation, isFalse);
    expect(VoicePreferences.keys, contains(VoicePreferences.conversationKey));
    expect(
      VoicePreferences.accepts(VoicePreferences.conversationKey, 'on'),
      isTrue,
    );
    expect(
      VoicePreferences.accepts(VoicePreferences.conversationKey, 'yes'),
      isFalse,
    );
    await saveDevicePreference(prefs, VoicePreferences.conversationKey, 'on');
    await prefs.reload();
    expect(VoicePreferences.read(prefs).conversation, isTrue);
    expect(VoicePreferences.read(prefs).autoSpeak, isFalse);
    await saveDevicePreference(prefs, VoicePreferences.conversationKey, 'off');
    await prefs.reload();
    expect(VoicePreferences.read(prefs).conversation, isFalse);
  });

  test('vad route and its settings persist with card defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    final initial = VoicePreferences.read(prefs);
    expect(initial.input, VoiceInputRoute.local);
    expect(initial.vad.pause, const Duration(milliseconds: 1800));
    expect(initial.vad.minSpeech, const Duration(milliseconds: 250));
    expect(initial.vad.preRoll, const Duration(milliseconds: 300));
    expect(initial.vad.maxDuration, const Duration(minutes: 10));
    expect(initial.vad.noSpeechTimeout, const Duration(seconds: 8));
    expect(initial.cues, isTrue);
    expect(initial.debugRecordings, isFalse);
    expect(initial.audioSource, VadAudioSource.communication);
    await saveDevicePreference(prefs, VoicePreferences.inputKey, 'vad');
    await saveDevicePreference(prefs, VoicePreferences.vadPauseKey, '2400');
    await saveDevicePreference(prefs, VoicePreferences.vadMinSpeechKey, '400');
    await saveDevicePreference(prefs, VoicePreferences.vadPreRollKey, '500');
    await saveDevicePreference(prefs, VoicePreferences.vadMaxKey, '900');
    await saveDevicePreference(prefs, VoicePreferences.vadNoSpeechKey, '12');
    await saveDevicePreference(prefs, VoicePreferences.vadCuesKey, 'off');
    await saveDevicePreference(prefs, VoicePreferences.vadDebugKey, 'on');
    await saveDevicePreference(
      prefs,
      VoicePreferences.vadSourceKey,
      'recognition',
    );
    await prefs.reload();
    final saved = VoicePreferences.read(prefs);
    expect(saved.input, VoiceInputRoute.vad);
    expect(saved.output, VoiceProcessing.local);
    expect(saved.vad.pause, const Duration(milliseconds: 2400));
    expect(saved.vad.minSpeech, const Duration(milliseconds: 400));
    expect(saved.vad.preRoll, const Duration(milliseconds: 500));
    expect(saved.vad.maxDuration, const Duration(minutes: 15));
    expect(saved.vad.noSpeechTimeout, const Duration(seconds: 12));
    expect(saved.cues, isFalse);
    expect(saved.debugRecordings, isTrue);
    expect(saved.audioSource, VadAudioSource.recognition);
  });

  test('vad choices are validated for backups; output never accepts vad', () {
    expect(VoicePreferences.accepts(VoicePreferences.inputKey, 'vad'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.outputKey, 'vad'), isFalse);
    for (final key in [
      VoicePreferences.vadPauseKey,
      VoicePreferences.vadMinSpeechKey,
      VoicePreferences.vadPreRollKey,
      VoicePreferences.vadMaxKey,
      VoicePreferences.vadNoSpeechKey,
      VoicePreferences.vadCuesKey,
      VoicePreferences.vadDebugKey,
      VoicePreferences.vadSourceKey,
    ]) {
      expect(VoicePreferences.keys, contains(key));
      expect(VoicePreferences.accepts(key, '0'), isFalse, reason: key);
    }
    expect(VoicePreferences.accepts(VoicePreferences.vadPauseKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.vadPauseKey, '0'), isFalse);
    expect(VoicePreferences.accepts(VoicePreferences.vadMaxKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.vadNoSpeechKey, '8'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.vadNoSpeechKey, '7'), isFalse);
    expect(
      VoicePreferences.accepts(VoicePreferences.vadSourceKey, 'recognition'),
      isTrue,
    );
    expect(VoicePreferences.keys, isNot(contains('voice.vad_microphone')));
    expect(VoicePreferences.accepts(VoicePreferences.vadDebugKey, 'on'), isTrue);
  });

  test('unknown stored vad values fall back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      VoicePreferences.vadPauseKey: '7',
      VoicePreferences.vadNoSpeechKey: '99',
    });
    final prefs = await SharedPreferences.getInstance();
    final read = VoicePreferences.read(prefs);
    expect(read.vad.pause, const Duration(milliseconds: 1800));
    expect(read.vad.noSpeechTimeout, const Duration(seconds: 8));
  });

  test('stored vad maximum below 10 minutes loads as the 10 minute default', () async {
    SharedPreferences.setMockInitialValues({
      VoicePreferences.vadMaxKey: '120',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(VoicePreferences.read(prefs).vad.maxDuration, const Duration(minutes: 10));
    expect(VoicePreferences.accepts(VoicePreferences.vadMaxKey, '120'), isFalse);
    for (final value in VoicePreferences.vadMaxChoices) {
      expect(int.parse(value), greaterThanOrEqualTo(600));
    }
  });

  test('barge-in preferences: defaults, parsing and validation', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var read = VoicePreferences.read(prefs);
    expect(read.listenTurn, isTrue);
    expect(read.listenMinSpeech, const Duration(milliseconds: 400));
    expect(read.bargeInPlayback, isFalse);
    SharedPreferences.setMockInitialValues({
      VoicePreferences.listenTurnKey: 'off',
      VoicePreferences.listenMinSpeechKey: '600',
      VoicePreferences.bargeInPlaybackKey: 'on',
    });
    prefs = await SharedPreferences.getInstance();
    read = VoicePreferences.read(prefs);
    expect(read.listenTurn, isFalse);
    expect(read.listenMinSpeech, const Duration(milliseconds: 600));
    expect(read.bargeInPlayback, isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.listenMinSpeechKey, '150'), isFalse);
    expect(VoicePreferences.accepts(VoicePreferences.listenTurnKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.bargeInPlaybackKey, 'maybe'), isFalse);
    expect(VoicePreferences.keys, containsAll([
      VoicePreferences.listenTurnKey,
      VoicePreferences.listenMinSpeechKey,
      VoicePreferences.bargeInPlaybackKey,
    ]));
  });

  Future<void> show(
    WidgetTester tester,
    SharedPreferences prefs,
    VoiceDeviceFixture device, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    VoidCallback? link,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        home: RepaintBoundary(
          key: frame,
          child: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: VoicePreferencesCard(
                  preferences: prefs,
                  device: device,
                  hermesProfileLabel: 'Personal',
                  openHermesSettings: link,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'output selection persists; remote voice is a profile link, not a picker',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final device = VoiceDeviceFixture();
      var links = 0;
      addTearDown(device.stream.close);
      await show(tester, prefs, device, link: () => links++);
      final output = tester
          .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
          .firstWhere((w) => w.label == 'Voice output');
      output.onChanged!('hermes');
      await tester.pumpAndSettle();
      expect(VoicePreferences.read(prefs).input, VoiceInputRoute.local);
      expect(VoicePreferences.read(prefs).output, VoiceProcessing.hermes);
      expect(find.text('Android voice'), findsNothing);
      expect(find.textContaining('belong to the selected server profile'), findsOneWidget);
      await tester.ensureVisible(find.text('Open speech synthesis'));
      await tester.tap(find.text('Open speech synthesis'));
      expect(links, 1);
      await tester.pumpWidget(const SizedBox());
      await show(tester, prefs, device);
      expect(
        tester
            .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
            .firstWhere((w) => w.label == 'Voice output')
            .value,
        'hermes',
      );
    },
  );
  testWidgets('failed preference save keeps confirmed value after reopening', (
    tester,
  ) async {
    final prefs = _FailingPreferences();
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    await show(tester, prefs, device);
    tester
        .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
        .firstWhere((w) => w.label == 'Voice input')
        .onChanged!('hermes');
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save this voice setting. Please retry.'),
      findsOneWidget,
    );
    expect(VoicePreferences.read(prefs).input, VoiceInputRoute.local);
    await tester.pumpWidget(const SizedBox());
    await show(tester, prefs, device);
    expect(
      tester
          .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
          .firstWhere((w) => w.label == 'Voice input')
          .value,
      'local',
    );
  });
  for (final brightness in Brightness.values) {
    testWidgets('voice settings fit 320dp at 200% text in $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.reset);
      final prefs = await SharedPreferences.getInstance();
      final device = VoiceDeviceFixture();
      device.capabilitiesValue = const AndroidVoiceCapabilities(
        recognitionAvailable: false,
        voices: [
          (
            id: 'long',
            label:
                'English (United Kingdom) · a very long installed Android voice name',
          ),
        ],
      );
      addTearDown(device.stream.close);
      await show(
        tester,
        prefs,
        device,
        brightness: brightness,
        scale: 2,
        link: () {},
      );
      await screenshot(tester, 'settings-input-${brightness.name}-200');
      await tester.ensureVisible(
        find.text('Refresh Android voices and languages'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'settings-output-${brightness.name}-200');
      tester
          .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
          .firstWhere((w) => w.label == 'Voice output')
          .onChanged!('hermes');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text('Refresh Android voices and languages'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'settings-hermes-${brightness.name}-200');
    });
  }
}
