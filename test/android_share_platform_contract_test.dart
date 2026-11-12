import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android advertises single and multiple file sharing', () async {
    final manifest = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();

    expect(manifest, contains('android.intent.action.SEND'));
    expect(manifest, contains('android.intent.action.SEND_MULTIPLE'));
    expect(manifest, contains('android:mimeType="*/*"'));
  });
}
