import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/voice_offline/vad_voice_device.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/voice_fixture.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  setUpAll(VoiceWorkspaceHarness.loadCaptureFonts);
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('listening row renders in $brightness at ${scale}x', (
        tester,
      ) async {
        await h.vadRoute();
        await h.conversationMode(true);
        await h.show(tester, brightness: brightness, scale: scale);
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pump();
        await h.windows(tester, 0.9, 30);
        await h.windows(tester, 0.1, 60);
        expect(find.text('Stop listening'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await h.screenshot(
          tester,
          'listen-${brightness.name}-${(scale * 100).round()}',
        );
        await tester.tap(find.text('Stop listening'));
        await h.settle(tester);
      });
    }
  }

  testWidgets('vad conversation sends after the pause', (tester) async {
    await h.listenTurn(false);
    await h.vadRoute();
    await h.conversationMode(true);
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(h.vadStarts(), 1);
    await h.windows(tester, 0.9, 30);
    await h.windows(tester, 0.1, 60);
    expect(h.device.finishes.single.reason.name, 'pause');
    expect(h.prompts(), 1);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Hello from the phone',
    );
    h.gatewayEvent('message.complete', {'text': 'Done.'});
    await h.settle(tester);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('vad thinking pause keeps the microphone open', (tester) async {
    await h.vadRoute();
    await h.conversationMode(true);
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await h.windows(tester, 0.9, 30);
    await h.windows(tester, 0.1, 31);
    expect(h.device.finishes, isEmpty);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    expect(h.prompts(), 0);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('media key ends a vad round and sends it in conversation mode', (
    tester,
  ) async {
    await h.listenTurn(false);
    await h.vadRoute();
    await h.conversationMode(true);
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await h.windows(tester, 0.9, 30);
    h.device.emitMediaKey();
    await h.settle(tester);
    expect(h.device.finishes.single.reason.name, 'mediaKey');
    expect(h.prompts(), 1);
    h.gatewayEvent('message.complete', {'text': 'Done.'});
    await h.settle(tester);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('media key starts a vad round when idle', (tester) async {
    await h.vadRoute();
    await h.show(tester);
    h.device.emitMediaKey();
    await h.settle(tester);
    expect(h.vadStarts(), 1);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('media key is ignored on the local route', (tester) async {
    await h.show(tester);
    h.device.emitMediaKey();
    await h.settle(tester);
    expect(h.starts(), 0);
    expect(h.vadStarts(), 0);
  });

  testWidgets('route vad preloads the model and enables media keys', (
    tester,
  ) async {
    await h.vadRoute();
    await h.show(tester);
    expect(h.device.prepares, 1);
    expect(h.device.mediaKeysCalls, [true]);
  });

  testWidgets('stacked workspaces leave media keys and screen on enabled', (
    tester,
  ) async {
    await h.vadRoute();
    await h.show(tester);
    expect(h.device.mediaKeysCalls, [true]);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ProfileWorkspaceScreen(
            controller: h.controller,
            voiceDevice: h.device,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.device.mediaKeysCalls, [true]);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(h.device.mediaKeysCalls.last, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(h.device.mediaKeysCalls.last, isFalse);
  });

  testWidgets('a non-chat destination never holds media keys', (tester) async {
    await h.vadRoute();
    await h.show(tester, destination: AppDestination.activity);
    expect(h.device.mediaKeysCalls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(h.device.mediaKeysCalls, isEmpty);
  });

  test('holders talk to the device only on the first and last holder', () {
    final fake = VoiceDeviceFixture();
    final holders = VoiceSwitchHolders.screenOn(fake);
    final a = Object(), b = Object();
    holders.set(a, true);
    holders.set(b, true);
    holders.set(a, false);
    expect(fake.keepScreenOnCalls, [true]);
    holders.set(b, false);
    holders.set(b, false);
    expect(fake.keepScreenOnCalls, [true, false]);
  });

  testWidgets('leaving the workspace releases media keys and the model', (
    tester,
  ) async {
    await h.vadRoute();
    await h.show(tester);
    expect(h.device.releases, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(h.device.mediaKeysCalls, [true, false]);
    expect(h.device.releases, 1);
  });

  testWidgets('backgrounding releases media keys and resume restores them', (
    tester,
  ) async {
    await h.vadRoute();
    await h.show(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(h.device.mediaKeysCalls, [true, false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(h.device.mediaKeysCalls, [true, false, true]);
  });

  testWidgets('a running conversation keeps the screen on until it ends', (
    tester,
  ) async {
    await h.conversationMode(true);
    await h.show(tester);
    expect(h.device.keepScreenOnCalls, isEmpty);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(h.device.keepScreenOnCalls, [true]);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
    expect(h.device.keepScreenOnCalls, [true, false]);
  });

  testWidgets('recording status shows the configured vad limit', (
    tester,
  ) async {
    await h.vadRoute();
    await h.controller.preferences.setString(VoiceOfflinePrefs.vadMaxKey, '900');
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(find.text('Recording · 0s / 900s'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('recording status shows the default vad limit of 10 minutes', (
    tester,
  ) async {
    await h.vadRoute();
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(find.text('Recording · 0s / 600s'), findsOneWidget);
    await h.screenshot(tester, 'vad-recording-light-100');
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

}
