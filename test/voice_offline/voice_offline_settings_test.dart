import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/barge_in_settings.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/headphone_route_fixture.dart';
import '../support/voice_fixture.dart';
import '../support/voice_settings_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadVoiceSettingsFonts);
  setUp(mockHeadphoneRouteChannel);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SharedPreferences> vadConversation() async {
    SharedPreferences.setMockInitialValues({
      'voice.input': 'local',
      VoiceOfflinePrefs.localEngineKey: 'parakeet',
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
    await showVoiceSettings(tester, await SharedPreferences.getInstance(), device);
    expect(find.text('Microphone'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final prefs = await vadConversation();
    await showVoiceSettings(tester, prefs, device);
    final mic = tester
        .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
        .firstWhere((w) => w.label == 'Microphone');
    expect(mic.value, 'auto');
    mic.onChanged!('bluetooth');
    await tester.pumpAndSettle();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.bluetooth);
    await tester.pumpWidget(const SizedBox());
    await showVoiceSettings(tester, prefs, device);
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
    await showVoiceSettings(tester, await SharedPreferences.getInstance(), device);
    expect(find.text('Listen while Hermes works'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final prefs = await vadConversation();
    await showVoiceSettings(tester, prefs, device);
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
    await showVoiceSettings(tester, prefs, device);
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
        await showVoiceSettings(tester, prefs, device, brightness: brightness, scale: scale);
        await tester.ensureVisible(find.text('Listen while Hermes works'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshotVoiceSettings(
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
            key: voiceSettingsFrame,
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: BargeInSettings(
                  vad: true,
                  output: null,
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
            await screenshotVoiceSettings(
              tester,
              'barge-playback-${allowed ? 'headphones' : 'wired'}-'
              '${brightness.name}-${(scale * 100).round()}',
            );
          },
        );
      }
    }
  }
}
