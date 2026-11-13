import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/turn_notification_service.dart';

void main() {
  group('notification identifiers', () {
    test('notification ids have a fixed cross-process value', () {
      expect(TurnNotificationService.notificationIdFor('turn-42'), 59289380);
    });

    test('notification ids separate canonical session owners', () {
      const original =
          '{"connection":"host","connection_identity":"owner-a",'
          '"profile":"default","session":"same"}';
      const replacement =
          '{"connection":"host","connection_identity":"owner-b",'
          '"profile":"default","session":"same"}';

      expect(
        TurnNotificationService.notificationIdFor(original),
        isNot(TurnNotificationService.notificationIdFor(replacement)),
      );
    });
  });
}
