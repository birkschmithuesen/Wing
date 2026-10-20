import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';

void main() {
  late PorterNoticeLedger ledger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ledger = PorterNoticeLedger(await SharedPreferences.getInstance());
  });

  test('a notice id is claimed once', () async {
    expect(await ledger.claim('n-3f2a9c1b7d4e'), isTrue);
    expect(await ledger.claim('n-3f2a9c1b7d4e'), isFalse);
  });

  test('release allows a retry', () async {
    await ledger.claim('n-3f2a9c1b7d4e');
    await ledger.release('n-3f2a9c1b7d4e');
    expect(await ledger.claim('n-3f2a9c1b7d4e'), isTrue);
  });

  test('concurrent claims of one id yield exactly one winner', () async {
    final results = await Future.wait([
      for (var i = 0; i < 5; i++) ledger.claim('n-9e8d7c6b5a41'),
    ]);
    expect(results.where((r) => r), hasLength(1));
  });

  test('only the last 32 ids are kept', () async {
    for (var i = 0; i < 40; i++) {
      await ledger.claim('n-${i.toRadixString(16).padLeft(12, '0')}');
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PorterNoticeLedger.key), hasLength(32));
  });
}
