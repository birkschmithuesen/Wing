import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const _accessibility = MethodChannel('com.tarkilhk.wing/accessibility');

/// The reading time Android recommends for text without interactive controls.
FutureOr<Duration> recommendedTextTimeout(Duration minimum) =>
    Platform.isAndroid ? _androidTextTimeout(minimum) : minimum;

Future<Duration> _androidTextTimeout(Duration minimum) async {
  final milliseconds = await _accessibility.invokeMethod<int>(
    'recommendedTextTimeout',
    minimum.inMilliseconds,
  );
  if (milliseconds == null) {
    throw StateError('The Android accessibility timeout returned no value.');
  }
  final recommended = Duration(milliseconds: milliseconds);
  return recommended < minimum ? minimum : recommended;
}
