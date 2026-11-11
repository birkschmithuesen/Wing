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
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/barge_in_settings.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import 'support/headphone_route_fixture.dart';
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

  // Unmocked, AndroidHeadphoneRouteHost.instance's real platform channel
  // never replies in a widget test and _probe's route read hangs forever.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.tarkilhk.wing/headphone_route'),
          (call) async => switch (call.method) {
            'current' => {'supported': false, 'type': 0},
            'bluetoothAllowed' => true,
            _ => null,
          },
        );
  });
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
      expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
    },
  );

  test('spoken replies toggle persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
    expect(VoicePreferences.keys, contains(VoiceOfflinePrefs.autoSpeakKey));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.autoSpeakKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.autoSpeakKey, 'off'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.autoSpeakKey, 'yes'), isFalse);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.autoSpeakKey, 'on');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isTrue);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.autoSpeakKey, 'off');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
  });

  test('conversation mode toggle persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).conversation, isFalse);
    expect(VoicePreferences.keys, contains(VoiceOfflinePrefs.conversationKey));
    expect(
      VoicePreferences.accepts(VoiceOfflinePrefs.conversationKey, 'on'),
      isTrue,
    );
    expect(
      VoicePreferences.accepts(VoiceOfflinePrefs.conversationKey, 'yes'),
      isFalse,
    );
    await saveDevicePreference(prefs, VoiceOfflinePrefs.conversationKey, 'on');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).conversation, isTrue);
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.conversationKey, 'off');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).conversation, isFalse);
  });

  test('vad route and its settings persist with card defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    final initial = VoicePreferences.read(prefs);
    final offline = VoiceOfflinePrefs.read(prefs);
    expect(initial.input, VoiceInputRoute.local);
    expect(offline.vad.pause, const Duration(milliseconds: 1800));
    expect(offline.vad.minSpeech, const Duration(milliseconds: 250));
    expect(offline.vad.preRoll, const Duration(milliseconds: 300));
    expect(offline.vad.maxDuration, const Duration(minutes: 10));
    expect(offline.vad.noSpeechTimeout, const Duration(seconds: 8));
    expect(offline.cues, isTrue);
    expect(offline.debugRecordings, isFalse);
    expect(offline.audioSource, VadAudioSource.communication);
    await saveDevicePreference(prefs, VoicePreferences.inputKey, 'vad');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadPauseKey, '2400');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadMinSpeechKey, '400');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadPreRollKey, '500');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadMaxKey, '900');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadNoSpeechKey, '12');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadCuesKey, 'off');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadDebugKey, 'on');
    await saveDevicePreference(
      prefs,
      VoiceOfflinePrefs.vadSourceKey,
      'recognition',
    );
    await prefs.reload();
    final saved = VoicePreferences.read(prefs);
    final savedOffline = VoiceOfflinePrefs.read(prefs);
    expect(saved.input, VoiceInputRoute.vad);
    expect(saved.output, VoiceProcessing.local);
    expect(savedOffline.vad.pause, const Duration(milliseconds: 2400));
    expect(savedOffline.vad.minSpeech, const Duration(milliseconds: 400));
    expect(savedOffline.vad.preRoll, const Duration(milliseconds: 500));
    expect(savedOffline.vad.maxDuration, const Duration(minutes: 15));
    expect(savedOffline.vad.noSpeechTimeout, const Duration(seconds: 12));
    expect(savedOffline.cues, isFalse);
    expect(savedOffline.debugRecordings, isTrue);
    expect(savedOffline.audioSource, VadAudioSource.recognition);
  });

  test('vad choices are validated for backups; output never accepts vad', () {
    expect(VoicePreferences.accepts(VoicePreferences.inputKey, 'vad'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.outputKey, 'vad'), isFalse);
    for (final key in [
      VoiceOfflinePrefs.vadPauseKey,
      VoiceOfflinePrefs.vadMinSpeechKey,
      VoiceOfflinePrefs.vadPreRollKey,
      VoiceOfflinePrefs.vadMaxKey,
      VoiceOfflinePrefs.vadNoSpeechKey,
      VoiceOfflinePrefs.vadCuesKey,
      VoiceOfflinePrefs.vadDebugKey,
      VoiceOfflinePrefs.vadSourceKey,
    ]) {
      expect(VoicePreferences.keys, contains(key));
      expect(VoicePreferences.accepts(key, '0'), isFalse, reason: key);
    }
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '0'), isFalse);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadMaxKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadNoSpeechKey, '8'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadNoSpeechKey, '7'), isFalse);
    expect(
      VoicePreferences.accepts(VoiceOfflinePrefs.vadSourceKey, 'recognition'),
      isTrue,
    );
    expect(VoicePreferences.keys, isNot(contains('voice.vad_microphone')));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadDebugKey, 'on'), isTrue);
  });

  test('vad pause accepts 4 s and 5 s for longer thinking pauses', () async {
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '4000'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '5000'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '4500'), isFalse);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '6000'), isFalse);
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadPauseKey: '5000',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(
      VoiceOfflinePrefs.read(prefs).vad.pause,
      const Duration(milliseconds: 5000),
    );
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadPauseKey: '4500',
    });
    final invalid = await SharedPreferences.getInstance();
    expect(
      VoiceOfflinePrefs.read(invalid).vad.pause,
      const Duration(milliseconds: 1800),
    );
  });

  test('unknown stored vad values fall back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadPauseKey: '7',
      VoiceOfflinePrefs.vadNoSpeechKey: '99',
    });
    final prefs = await SharedPreferences.getInstance();
    final read = VoiceOfflinePrefs.read(prefs);
    expect(read.vad.pause, const Duration(milliseconds: 1800));
    expect(read.vad.noSpeechTimeout, const Duration(seconds: 8));
  });

  test('stored vad maximum below 10 minutes loads as the 10 minute default', () async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadMaxKey: '120',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).vad.maxDuration, const Duration(minutes: 10));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadMaxKey, '120'), isFalse);
    for (final value in VoiceOfflinePrefs.vadMaxChoices) {
      expect(int.parse(value), greaterThanOrEqualTo(600));
    }
  });

  test('barge-in preferences: defaults, parsing and validation', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var read = VoiceOfflinePrefs.read(prefs);
    expect(read.listenTurn, isTrue);
    expect(read.listenMinSpeech, const Duration(milliseconds: 400));
    expect(read.bargeInPlayback, isFalse);
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.listenTurnKey: 'off',
      VoiceOfflinePrefs.listenMinSpeechKey: '600',
      VoiceOfflinePrefs.bargeInPlaybackKey: 'on',
    });
    prefs = await SharedPreferences.getInstance();
    read = VoiceOfflinePrefs.read(prefs);
    expect(read.listenTurn, isFalse);
    expect(read.listenMinSpeech, const Duration(milliseconds: 600));
    expect(read.bargeInPlayback, isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.listenMinSpeechKey, '150'), isFalse);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.listenTurnKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.bargeInPlaybackKey, 'maybe'), isFalse);
    expect(VoicePreferences.keys, containsAll([
      VoiceOfflinePrefs.listenTurnKey,
      VoiceOfflinePrefs.listenMinSpeechKey,
      VoiceOfflinePrefs.bargeInPlaybackKey,
    ]));
  });

  test('mic route: defaults to automatic, persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.auto);
    expect(VoicePreferences.keys, contains(VoiceOfflinePrefs.micRouteKey));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'auto'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'phone'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'bluetooth'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'wired'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'usb'), isFalse);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.micRouteKey, 'bluetooth');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.bluetooth);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.micRouteKey, 'wired');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.wired);
  });

  test('an unknown stored mic route falls back to automatic', () async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.micRouteKey: 'usb',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.auto);
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

  Future<SharedPreferences> vadConversation() async {
    SharedPreferences.setMockInitialValues({
      VoicePreferences.inputKey: 'vad',
      VoiceOfflinePrefs.conversationKey: 'on',
    });
    return SharedPreferences.getInstance();
  }

  testWidgets('microphone choice appears only with the on-phone route and saves', (
    tester,
  ) async {
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    SharedPreferences.setMockInitialValues({});
    await show(tester, await SharedPreferences.getInstance(), device);
    expect(find.text('Microphone'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final prefs = await vadConversation();
    await show(tester, prefs, device);
    final mic = tester
        .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
        .firstWhere((w) => w.label == 'Microphone');
    expect(mic.value, 'auto');
    mic.onChanged!('bluetooth');
    await tester.pumpAndSettle();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.bluetooth);
    await tester.pumpWidget(const SizedBox());
    await show(tester, prefs, device);
    expect(
      tester
          .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
          .firstWhere((w) => w.label == 'Microphone')
          .value,
      'bluetooth',
    );
  });

  testWidgets('listen-while-working settings appear only with vad conversation', (
    tester,
  ) async {
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    SharedPreferences.setMockInitialValues({});
    await show(tester, await SharedPreferences.getInstance(), device);
    expect(find.text('Listen while Hermes works'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final prefs = await vadConversation();
    await show(tester, prefs, device);
    await tester.ensureVisible(find.text('Listen while Hermes works'));
    expect(find.text('Speech needed to steer'), findsOneWidget);
    expect(
      find.text('Interrupt read-aloud by speaking'),
      bargeInPlaybackAvailable ? findsOneWidget : findsNothing,
    );
    expect(find.text('Measure speaker echo'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('voice-listen-turn')));
    await tester.pumpAndSettle();
    expect(VoiceOfflinePrefs.read(prefs).listenTurn, isFalse);
    expect(find.text('Speech needed to steer'), findsNothing);
  });

  testWidgets('echo probe plays the synthetic text while a listen round records', (
    tester,
  ) async {
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    final prefs = await vadConversation();
    await prefs.setString(VoiceOfflinePrefs.vadDebugKey, 'on');
    await show(tester, prefs, device);
    await tester.ensureVisible(find.text('Measure speaker echo'));
    await tester.tap(find.text('Measure speaker echo'));
    await tester.pumpAndSettle();
    expect(device.calls, containsAllInOrder(['startVad', 'speak']));
    expect(device.vadOptions!.keepPlayback, isTrue);
    expect(device.spoken, contains('Messtext'));
    expect(find.text('Measure speaker echo'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('barge-in settings render in $brightness at ${scale}x', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        final prefs = await vadConversation();
        await prefs.setString(VoiceOfflinePrefs.vadDebugKey, 'on');
        final device = VoiceDeviceFixture();
        addTearDown(device.stream.close);
        await show(tester, prefs, device, brightness: brightness, scale: scale);
        await tester.ensureVisible(find.text('Listen while Hermes works'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(
          tester,
          'barge-settings-${brightness.name}-${(scale * 100).round()}',
        );
      });
    }
  }

  const headphonesOnly =
      'Only with headphones. On the speaker or in the car, tap to stop.';
  const headphonesWiredOrBluetooth =
      'Only with headphones (wired or Bluetooth). On the speaker or in the car, tap to stop.';
  const playbackOff = VoiceOfflinePrefs(conversation: true);
  const playbackOn = VoiceOfflinePrefs(
    conversation: true,
    bargeInPlayback: true,
  );

  Future<List<(String, String)>> showBargeIn(
    WidgetTester tester,
    VoiceOfflinePrefs offline,
    HeadphoneRouteFixture route, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    final saved = <(String, String)>[];
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: RepaintBoundary(
            key: frame,
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: BargeInSettings(
                  settings: const VoicePreferences(input: VoiceInputRoute.vad),
                  offline: offline,
                  device: device,
                  saving: false,
                  onSave: (key, value) async => saved.add((key, value)),
                  route: route,
                  playbackAvailable: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('read-aloud barge-in states the headphones-only rule', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture();
    addTearDown(route.close);
    await showBargeIn(tester, playbackOff, route);
    expect(find.text('Interrupt read-aloud by speaking'), findsOneWidget);
    expect(find.text(headphonesOnly), findsOneWidget);
  });

  testWidgets('switching it on saves and asks for Bluetooth access', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture();
    addTearDown(route.close);
    final saved = await showBargeIn(tester, playbackOff, route);
    await tester.tap(find.byKey(const ValueKey('voice-barge-in-playback')));
    await tester.pumpAndSettle();
    expect(saved, [(VoiceOfflinePrefs.bargeInPlaybackKey, 'on')]);
    expect(route.requests, 1);
  });

  testWidgets('without Bluetooth access the row mentions wired or Bluetooth', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture()..allowed = false;
    addTearDown(route.close);
    await showBargeIn(tester, playbackOn, route);
    expect(find.text(headphonesWiredOrBluetooth), findsOneWidget);
    expect(find.text(headphonesOnly), findsNothing);
  });

  testWidgets('with Bluetooth access the row still mentions wired or Bluetooth', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture()..allowed = true;
    addTearDown(route.close);
    await showBargeIn(tester, playbackOn, route);
    expect(find.text(headphonesWiredOrBluetooth), findsOneWidget);
    expect(find.text(headphonesOnly), findsNothing);
  });

  testWidgets('switching it off does not ask for anything', (tester) async {
    final route = HeadphoneRouteFixture();
    addTearDown(route.close);
    final saved = await showBargeIn(tester, playbackOn, route);
    await tester.tap(find.byKey(const ValueKey('voice-barge-in-playback')));
    await tester.pumpAndSettle();
    expect(saved, [(VoiceOfflinePrefs.bargeInPlaybackKey, 'off')]);
    expect(route.requests, 0);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final allowed in [true, false]) {
        testWidgets(
          'read-aloud barge-in row renders in $brightness at ${scale}x '
          '(bluetooth ${allowed ? 'allowed' : 'denied'})',
          (tester) async {
            final route = HeadphoneRouteFixture()..allowed = allowed;
            addTearDown(route.close);
            await showBargeIn(
              tester,
              playbackOn,
              route,
              brightness: brightness,
              scale: scale,
            );
            await tester.ensureVisible(
              find.text('Interrupt read-aloud by speaking'),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await screenshot(
              tester,
              'barge-playback-${allowed ? 'headphones' : 'wired'}-'
              '${brightness.name}-${(scale * 100).round()}',
            );
          },
        );
      }
    }
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
