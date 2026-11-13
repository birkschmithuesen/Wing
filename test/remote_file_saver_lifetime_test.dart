import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/remote_file_saver.dart';
import 'package:wing/core/services/remote_files_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a staging write failure releases its undispatched temporary directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wing-output-lifetime-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      await expectLater(
        shareRemoteFile(
          RemoteFileDownload(filename: 'missing/child.txt', bytes: [1]),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );
}
