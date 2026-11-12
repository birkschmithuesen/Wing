import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/services/android_voice.dart';

/// Run on a disposable emulator after revoking RECORD_AUDIO. At the first
/// Android dialog choose Don't allow, at the second choose While using the app.
/// Press Home when VOICE_BACKGROUND_READY is printed. No server is contacted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native denial, retry/grant and background capture cancellation',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Wing microphone permission acceptance')),
          ),
        ),
      );
      final device = AndroidVoice.instance;
      debugPrint('VOICE_DENY_READY');
      await expectLater(
        device.start('permission-denied', local: false, language: ''),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'permission_denied',
          ),
        ),
      );
      debugPrint('VOICE_GRANT_READY');
      expect(await AndroidVoice.requestPermission(), isTrue);
      final cancelled = device.events.firstWhere(
        (event) =>
            event['id'] == 'background-capture' && event['error'] is String,
      );
      await device.start('background-capture', local: false, language: '');
      debugPrint('VOICE_BACKGROUND_READY');
      final event = await cancelled.timeout(const Duration(seconds: 40));
      expect(event['error'], contains('left the foreground'));
      expect(await device.stop('background-capture'), isNull);
      debugPrint('VOICE_BACKGROUND_CANCELLED');
    },
  );
}
