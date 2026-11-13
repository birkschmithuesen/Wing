import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/connection_manager.dart'
    show ConnectionManager, CredentialStore;

class _Credentials implements CredentialStore {
  final _values = <String, String>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final outcome in ['success', 'dismissal', 'error']) {
    test(
      'Android export removes only its stage after native $outcome',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'wing-backup-outcome-',
        );
        final unrelated = File('${directory.path}/other-owner.json');
        await unrelated.writeAsString('retain');
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final entered = Completer<File>();
        final settled = Completer<String>();
        messenger.setMockMethodCallHandler(
          pathChannel,
          (_) async => directory.path,
        );
        messenger.setMockMethodCallHandler(shareChannel, (call) {
          final paths = List<String>.from(
            (call.arguments as Map)['paths'] as List,
          );
          entered.complete(File(paths.single));
          return settled.future;
        });
        addTearDown(() async {
          messenger.setMockMethodCallHandler(pathChannel, null);
          messenger.setMockMethodCallHandler(shareChannel, null);
          await directory.delete(recursive: true);
        });
        final pending = ConfigBackupIo().deliverExport(
          'backup-secret',
          canDispatch: () => true,
        );
        final source = await entered.future;
        expect(await source.readAsString(), 'backup-secret');
        if (outcome == 'error') {
          final failed = expectLater(
            pending,
            throwsA(isA<PlatformException>()),
          );
          settled.completeError(PlatformException(code: 'native-share-error'));
          await failed;
        } else {
          settled.complete(outcome == 'dismissal' ? '' : 'recipient');
          expect(await pending, outcome == 'dismissal' ? isNull : isNotNull);
        }
        expect(await source.parent.exists(), isFalse);
        expect(await unrelated.readAsString(), 'retain');
      },
    );
  }

  test(
    'non-Android admitted source remains available after settlement',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final directory = await Directory.systemTemp.createTemp(
        'wing-backup-ios-',
      );
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? sharedPath;
      messenger.setMockMethodCallHandler(
        pathChannel,
        (_) async => directory.path,
      );
      messenger.setMockMethodCallHandler(shareChannel, (call) async {
        sharedPath =
            ((call.arguments as Map)['paths'] as List).single as String;
        return 'recipient';
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null);
        messenger.setMockMethodCallHandler(shareChannel, null);
        await directory.delete(recursive: true);
      });
      expect(
        await ConfigBackupIo().deliverExport(
          'backup-secret',
          canDispatch: () => true,
        ),
        isNotNull,
      );
      expect(await File(sharedPath!).readAsString(), 'backup-secret');
    },
  );

  test(
    'closing during real export preparation prevents native share',
    () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      PackageInfo.setMockInitialValues(
        appName: 'Wing',
        packageName: 'com.tarkilhk.wing',
        version: 'fixture',
        buildNumber: '1',
        buildSignature: '',
      );
      final storage = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(
        storage,
        credentialStore: _Credentials(),
      );
      final owner = AppPreferences(storage);
      final session = BackupSession(
        configuration: ConfigBackupService(
          connectionManager: manager,
          appPreferences: owner,
        ),
        io: ConfigBackupIo(),
      );
      final directory = await Directory.systemTemp.createTemp(
        'wing-backup-export-lifetime-',
      );
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final directoryEntered = Completer<void>();
      final directoryResult = Completer<String>();
      var shareDispatches = 0;
      final sharedPaths = <String>[];
      messenger.setMockMethodCallHandler(pathChannel, (call) {
        expect(call.method, 'getTemporaryDirectory');
        directoryEntered.complete();
        return directoryResult.future;
      });
      messenger.setMockMethodCallHandler(shareChannel, (call) async {
        expect(call.method, 'share');
        shareDispatches++;
        sharedPaths.addAll(
          List<String>.from((call.arguments as Map)['paths'] as List),
        );
        return 'fixture-recipient';
      });
      addTearDown(() async {
        session.close();
        owner.dispose();
        messenger.setMockMethodCallHandler(pathChannel, null);
        messenger.setMockMethodCallHandler(shareChannel, null);
        await directory.delete(recursive: true);
      });

      var publications = 0;
      session.presentation.addListener(() => publications++);
      final attempt = session.beginExport()!;
      final pending = session.export(
        attempt,
        BackupExportIntent(passphrase: '', confirmation: ''),
      );
      await directoryEntered.future;
      expect(shareDispatches, 0);
      expect(await directory.list().toList(), isEmpty);
      final beforeClose = publications;

      session.close();
      directoryResult.complete(directory.path);
      final result = await pending;

      // Assert physical effects before the logical refusal/publication result.
      expect(shareDispatches, 0);
      expect(sharedPaths, isEmpty);
      expect(await directory.list().toList(), isEmpty);
      expect(result, isNull);
      expect(publications, beforeClose);
    },
  );

  test(
    'Android share keeps pending source then releases it while recipient copy remains readable',
    () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      PackageInfo.setMockInitialValues(
        appName: 'Wing',
        packageName: 'com.tarkilhk.wing',
        version: 'fixture',
        buildNumber: '1',
        buildSignature: '',
      );
      final storage = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(
        storage,
        credentialStore: _Credentials(),
      );
      final owner = AppPreferences(storage);
      final session = BackupSession(
        configuration: ConfigBackupService(
          connectionManager: manager,
          appPreferences: owner,
        ),
        io: ConfigBackupIo(),
      );
      final directory = await Directory.systemTemp.createTemp(
        'wing-backup-share-settlement-',
      );
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final shareEntered = Completer<String>();
      final shareResult = Completer<String>();
      final recipientCopy = File('${directory.path}/recipient-copy.json');
      var shareDispatches = 0;
      messenger.setMockMethodCallHandler(pathChannel, (call) async {
        expect(call.method, 'getTemporaryDirectory');
        return directory.path;
      });
      messenger.setMockMethodCallHandler(shareChannel, (call) async {
        expect(call.method, 'share');
        shareDispatches++;
        final paths = List<String>.from(
          (call.arguments as Map)['paths'] as List,
        );
        expect(paths, hasLength(1));
        // The pinned Android plugin copies the source into provider storage
        // before presenting the chooser. Model that boundary, not its internals.
        await File(paths.single).copy(recipientCopy.path);
        shareEntered.complete(paths.single);
        return shareResult.future;
      });
      addTearDown(() async {
        session.close();
        owner.dispose();
        messenger.setMockMethodCallHandler(pathChannel, null);
        messenger.setMockMethodCallHandler(shareChannel, null);
        await directory.delete(recursive: true);
      });

      var publications = 0;
      session.presentation.addListener(() => publications++);
      final pending = session.export(
        session.beginExport()!,
        BackupExportIntent(passphrase: '', confirmation: ''),
      );
      final sharedFile = File(await shareEntered.future);
      expect(shareDispatches, 1);
      final contents = await sharedFile.readAsString();
      final beforeClose = publications;

      session.close();
      expect(await sharedFile.readAsString(), contents);
      shareResult.complete('fixture-recipient');
      final result = await pending;

      // Recipient storage remains readable independently of Wing's source.
      expect(shareDispatches, 1);
      expect(await sharedFile.parent.exists(), isFalse);
      expect(await recipientCopy.readAsString(), contents);
      expect(result, isNull);
      expect(publications, beforeClose);
    },
  );
}
