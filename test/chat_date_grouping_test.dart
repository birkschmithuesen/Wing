import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_list_view.dart';

void main() {
  for (final (name, now, yesterday, elapsed) in [
    ('spring forward', DateTime(2026, 3, 9), DateTime(2026, 3, 8), 23),
    ('fall back', DateTime(2026, 11, 2), DateTime(2026, 11, 1), 25),
  ]) {
    test('$name uses calendar dates for Yesterday and seven-day edges', () {
      // The focused TZ=America/New_York run also verifies the real transition.
      if (Platform.environment['TZ'] == 'America/New_York') {
        expect(now.difference(yesterday).inHours, elapsed);
      }
      expect(chatDateBucket(yesterday, now: now), 'Yesterday');
      expect(chatDateBucket(now, now: now), 'Today');
      expect(
        chatDateBucket(DateTime(now.year, now.month, now.day - 6), now: now),
        'Previous 7 days',
      );
      expect(
        chatDateBucket(DateTime(now.year, now.month, now.day - 7), now: now),
        'Older',
      );
    });
  }
  test('local calendar dates cross month and year boundaries', () {
    expect(
      chatDateBucket(DateTime(2025, 12, 31, 23), now: DateTime(2026, 1, 1, 1)),
      'Yesterday',
    );
    expect(
      chatDateBucket(DateTime(2026, 2, 28, 23), now: DateTime(2026, 3, 1, 1)),
      'Yesterday',
    );
  });
}
