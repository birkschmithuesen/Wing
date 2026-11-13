import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/phone_reading_test.dart' as phone_reading;

import '../test/profile_transcript_test.dart' as transcript;
import '../test/profile_streaming_scroll_test.dart' as streaming;
import '../test/profile_activity_details_layout_test.dart' as activity;

/// Runs the transcript scroll regressions on Android using only local fixtures.
/// Run with --no-uninstall on a disposable emulator.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var convertedSurface = false;
  setUp(() => convertedSurface = false);
  Future<void> capture(WidgetTester tester, String name) async {
    if (!convertedSurface) {
      await binding.convertFlutterSurfaceToImage();
      convertedSurface = true;
      await tester.pumpAndSettle();
    }
    final bytes = await binding.takeScreenshot(name);
    final directory = await getExternalStorageDirectory();
    await File('${directory!.path}/$name.png').writeAsBytes(bytes);
  }

  transcript.main(capture: capture);
  streaming.main(captureFrame: capture);
  activity.main(capture: capture);
  phone_reading.main(
    capture: capture,
    rotate: (tester, landscape) async {
      await SystemChrome.setPreferredOrientations([
        landscape
            ? DeviceOrientation.landscapeLeft
            : DeviceOrientation.portraitUp,
      ]);
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        final size = tester.view.physicalSize;
        if ((size.width > size.height) == landscape) return;
      }
      fail('Android did not apply the requested orientation.');
    },
  );
}
