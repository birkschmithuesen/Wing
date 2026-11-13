import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test/unread_runtime_repro_test.dart' as regression;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  regression.unreadRuntimeContract(
    onVerified: (tester, name) async {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      final bytes = await binding.takeScreenshot('unread-runtime-$name');
      final file = File(
        '${Directory.systemTemp.path}/unread-runtime-$name.png',
      );
      await file.writeAsBytes(bytes);
      // Capture paths only; the emulator fixture contains no real account data.
      // ignore: avoid_print
      print('UNREAD_VERIFIED_CAPTURE ${file.path}');
    },
  );
}
