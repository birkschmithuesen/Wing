import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/platform_share.dart';
import 'package:wing/core/services/remote_file_saver.dart';
import 'package:wing/core/services/remote_files_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final fails in [false, true]) {
    test(
      'pending backup rejects other file offers and releases admission after ${fails ? 'error' : 'success'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'wing-share-admission-',
        );
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final firstEntered = Completer<File>();
        final settled = Completer<String>();
        final sharedPaths = <String>[];
        messenger.setMockMethodCallHandler(
          pathChannel,
          (_) async => directory.path,
        );
        messenger.setMockMethodCallHandler(shareChannel, (call) {
          final source = File(
            ((call.arguments as Map)['paths'] as List).single as String,
          );
          sharedPaths.add(source.path);
          if (sharedPaths.length == 1) {
            // Native preparation has entered but has not copied this source yet.
            firstEntered.complete(source);
            return settled.future;
          }
          return Future.value('recipient');
        });
        addTearDown(() async {
          messenger.setMockMethodCallHandler(pathChannel, null);
          messenger.setMockMethodCallHandler(shareChannel, null);
          await directory.delete(recursive: true);
        });
        final io = ConfigBackupIo();
        final first = io.deliverExport('first secret', canDispatch: () => true);
        final source = await firstEntered.future;
        try {
          await expectLater(
            io.deliverExport('second secret', canDispatch: () => true),
            throwsA(
              isA<ConfigBackupException>().having(
                (e) => e.message,
                'message',
                contains('current share sheet'),
              ),
            ),
          );
          await expectLater(
            shareRemoteFile(
              RemoteFileDownload(filename: 'report.txt', bytes: [1]),
            ),
            throwsA(isA<PlatformShareBusy>()),
          );
          await expectLater(
            platformShare(ShareParams(text: 'Received skill text')),
            throwsA(isA<PlatformShareBusy>()),
          );
          expect(
            sharedPaths,
            [source.path],
            reason: 'No second native call may supersede the preparing offer',
          );
          expect(await source.readAsString(), 'first secret');
          expect(
            (await directory.list().toList()).map((entry) => entry.path),
            [source.parent.path],
            reason: 'Rejected backup and output offers release their stages',
          );
        } finally {
          if (fails) {
            final failed = expectLater(
              first,
              throwsA(isA<PlatformException>()),
            );
            settled.completeError(
              PlatformException(code: 'preparation-failed'),
            );
            await failed;
          } else {
            settled.complete('recipient');
            await first;
          }
        }
        expect(await source.parent.exists(), isFalse);
        expect(
          await io.deliverExport('later secret', canDispatch: () => true),
          isNotNull,
        );
        expect(sharedPaths, hasLength(2));
        expect(
          sharedPaths.map((path) => File(path).uri.pathSegments.last).toSet(),
          hasLength(2),
        );
        expect(await directory.list().toList(), isEmpty);
      },
    );
  }
}
