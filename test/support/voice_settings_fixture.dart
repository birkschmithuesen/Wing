import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/voice_preferences_card.dart';
import 'voice_fixture.dart';

const voiceSettingsCapture = bool.fromEnvironment('VOICE_REVIEW');
const voiceSettingsFrame = Key('voice-settings-frame');

Future<void> loadVoiceSettingsFonts() async {
  if (!voiceSettingsCapture) return;
  const path = String.fromEnvironment('CAPTURE_FONT_DIR');
  for (final entry in {
    'Roboto': 'Roboto-Regular.ttf',
    'MaterialIcons': 'MaterialIcons-Regular.otf',
  }.entries) {
    final loader = FontLoader(entry.key)
      ..addFont(
        Future.value(
          ByteData.sublistView(File('$path/${entry.value}').readAsBytesSync()),
        ),
      );
    await loader.load();
  }
}

Future<void> screenshotVoiceSettings(WidgetTester tester, String name) async {
  if (!voiceSettingsCapture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(voiceSettingsFrame),
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
void mockHeadphoneRouteChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('com.tarkilhk.wing/headphone_route'),
        (call) async => switch (call.method) {
          'current' => {'supported': false, 'type': 0},
          'bluetoothAllowed' => true,
          _ => null,
        },
      );
}

Future<void> showVoiceSettings(
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
        key: voiceSettingsFrame,
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
