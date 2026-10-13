import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/widgets/voice_preferences_card.dart';
import 'support/voice_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('vad-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(
          Future.value(ByteData.sublistView(File('$path/$name').readAsBytesSync())),
        );
      }
      await loader.load();
    }
  });

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File('build/voice-review/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  late VoiceDeviceFixture device;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({VoicePreferences.inputKey: 'vad'});
    prefs = await SharedPreferences.getInstance();
    device = VoiceDeviceFixture();
  });
  tearDown(() => device.stream.close());

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        home: RepaintBoundary(
          key: frame,
          child: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: VoicePreferencesCard(preferences: prefs, device: device),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  StudioSelect<String> select(WidgetTester tester, String label) => tester
      .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
      .firstWhere((w) => w.label == label);

  testWidgets('route vad offers the model download and hides the language', (tester) async {
    device.modelStatus = const VadModelStatus(state: VadModelState.absent);
    await show(tester);
    expect(select(tester, 'Voice input').value, 'vad');
    expect(find.text('Recognition language'), findsNothing);
    expect(find.text('Speech model · 487 MB download'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vad-model-download')));
    await tester.pump();
    expect(device.installs, 1);
    await screenshot(tester, 'vad-model-absent-light-100');
  });

  testWidgets('download progress is shown and can be cancelled', (tester) async {
    device.modelStatus = const VadModelStatus(state: VadModelState.absent);
    await show(tester);
    device.emitModel(const VadModelStatus(
      state: VadModelState.downloading,
      bytes: 123000000,
      total: 487170055,
    ));
    await tester.pump();
    expect(find.text('123 / 487 MB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await screenshot(tester, 'vad-model-downloading-light-100');
    await tester.tap(find.byKey(const ValueKey('vad-model-cancel')));
    await tester.pump();
    expect(device.cancelInstalls, 1);
    device.emitModel(const VadModelStatus(state: VadModelState.unpacking));
    await tester.pump();
    expect(find.text('Unpacking…'), findsOneWidget);
  });

  testWidgets('a failed install shows the error and retries', (tester) async {
    device.modelStatus = const VadModelStatus(
      state: VadModelState.failed,
      error: 'Download was corrupted. Retry.',
    );
    await show(tester);
    expect(find.text('Download was corrupted. Retry.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vad-model-retry')));
    await tester.pump();
    expect(device.installs, 1);
    await screenshot(tester, 'vad-model-failed-light-100');
  });

  testWidgets('an installed model can be removed after confirmation', (tester) async {
    await show(tester);
    expect(find.text('Speech model ready'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vad-model-remove')));
    await tester.pumpAndSettle();
    expect(device.removals, 0);
    await tester.tap(find.byKey(const ValueKey('vad-model-remove-confirm')));
    await tester.pumpAndSettle();
    expect(device.removals, 1);
  });

  testWidgets('cues and pause detection settings persist; no microphone choice', (tester) async {
    await show(tester);
    expect(find.text('Microphone'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('vad-cues')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Pause detection'));
    await tester.tap(find.text('Pause detection'));
    await tester.pumpAndSettle();
    select(tester, 'Pause before sending').onChanged!('2400');
    await tester.pumpAndSettle();
    expect(select(tester, 'Wait for speech').value, '8');
    select(tester, 'Wait for speech').onChanged!('12');
    await tester.pumpAndSettle();
    select(tester, 'Minimum speech').onChanged!('400');
    await tester.pumpAndSettle();
    select(tester, 'Lead-in kept').onChanged!('500');
    await tester.pumpAndSettle();
    select(tester, 'Longest recording').onChanged!('60');
    await tester.pumpAndSettle();
    final saved = VoicePreferences.read(prefs);
    expect(saved.cues, isFalse);
    expect(saved.vad.pause, const Duration(milliseconds: 2400));
    expect(saved.vad.noSpeechTimeout, const Duration(seconds: 12));
    expect(saved.vad.minSpeech, const Duration(milliseconds: 400));
    expect(saved.vad.preRoll, const Duration(milliseconds: 500));
    expect(saved.vad.maxDuration, const Duration(seconds: 60));
  });

  testWidgets('debug recordings reveal the audio source and delete action', (tester) async {
    await show(tester);
    await tester.ensureVisible(find.text('Pause detection'));
    await tester.tap(find.text('Pause detection'));
    await tester.pumpAndSettle();
    expect(find.text('Audio source'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('vad-debug')));
    await tester.tap(find.byKey(const ValueKey('vad-debug')));
    await tester.pumpAndSettle();
    expect(VoicePreferences.read(prefs).debugRecordings, isTrue);
    expect(find.text('Audio source'), findsOneWidget);
    select(tester, 'Audio source').onChanged!('recognition');
    await tester.pumpAndSettle();
    expect(VoicePreferences.read(prefs).audioSource, VadAudioSource.recognition);
    await tester.ensureVisible(find.byKey(const ValueKey('vad-debug-delete')));
    await tester.tap(find.byKey(const ValueKey('vad-debug-delete')));
    await tester.pumpAndSettle();
    expect(device.debugDeletes, 1);
    await screenshot(tester, 'vad-pause-detection-open-light-100');
  });

  testWidgets('switching the route prepares or releases the phone model', (tester) async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await show(tester);
    select(tester, 'Voice input').onChanged!('vad');
    await tester.pumpAndSettle();
    expect(device.prepares, 1);
    expect(device.mediaKeysCalls, isEmpty);
    select(tester, 'Voice input').onChanged!('local');
    await tester.pumpAndSettle();
    expect(device.releases, 1);
    expect(device.mediaKeysCalls, isEmpty);
  });

  for (final brightness in Brightness.values) {
    testWidgets('vad settings fit 320dp at 200% text in $brightness', (tester) async {
      device.modelStatus = const VadModelStatus(
        state: VadModelState.downloading,
        bytes: 300000000,
        total: 487170055,
      );
      SharedPreferences.setMockInitialValues({
        VoicePreferences.inputKey: 'vad',
        VoicePreferences.vadDebugKey: 'on',
      });
      prefs = await SharedPreferences.getInstance();
      await show(tester, brightness: brightness, scale: 2);
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'vad-settings-${brightness.name}-200');
      await tester.ensureVisible(find.text('Pause detection'));
      await tester.tap(find.text('Pause detection'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('vad-debug-delete')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'vad-settings-open-${brightness.name}-200');
    });
  }
}
