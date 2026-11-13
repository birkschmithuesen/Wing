import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/notification_delivery_ledger.dart';

void main() {
  late SharedPreferences preferences;
  late NotificationDeliveryLedger ledger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    ledger = NotificationDeliveryLedger(preferences);
  });

  test('concurrent claims admit each event only once', () async {
    expect(
      await Future.wait([
        ledger.claim('one'),
        ledger.claim('one'),
        ledger.claim('two'),
      ]),
      [true, false, true],
    );
  });

  test('releasing a failed delivery permits that event to retry', () async {
    expect(await ledger.claim('one'), isTrue);
    expect(await ledger.claim('two'), isTrue);
    await ledger.release('one');
    expect(await ledger.claim('one'), isTrue);
    expect(await ledger.claim('two'), isFalse);
  });

  test(
    'claimed events remain deduplicated after reopening the ledger',
    () async {
      expect(await ledger.claim('one'), isTrue);
      final reopened = NotificationDeliveryLedger(preferences);
      expect(await reopened.claim('one'), isFalse);
      expect(await reopened.claim('new-event'), isTrue);
    },
  );
}
