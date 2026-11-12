import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wing/core/services/config_backup_io.dart';

/// Run with scripts/test_native_file_transfer.py on a disposable emulator.
/// The host selects fixture files and dismisses native dialogs at the markers.
/// No Hermes connection or real configuration is used.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const contents = '{"probe":"Wing native file transfer — ✓"}';
  late ConfigBackupIo backupIo;

  Future<({Set<String> files, Set<String> stages})>
  fixtureCacheInventory() async {
    final cache = await getTemporaryDirectory();
    final files = <String>{};
    final stages = <String>{};
    for (final stage
        in cache.listSync(followLinks: false).whereType<Directory>()) {
      if (!stage.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last
          .startsWith('wing-backup-')) {
        continue;
      }
      stages.add(stage.path);
      for (final file
          in stage
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        files.add(file.path);
      }
    }
    for (final name in ['file_picker', 'share_plus']) {
      final directory = Directory('${cache.path}/$name');
      if (!await directory.exists()) continue;
      for (final file
          in directory
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        final filename = file.uri.pathSegments.last;
        if ((name == 'share_plus' && filename.startsWith('wing-config-')) ||
            (name == 'file_picker' &&
                [
                  'wing-native-probe.json',
                  'wing-native-probe.png',
                ].contains(filename))) {
          files.add(file.path);
        }
      }
    }
    return (files: files, stages: stages);
  }

  setUp(() async {
    backupIo = ConfigBackupIo();
    final previous = await fixtureCacheInventory();
    addTearDown(() async {
      final current = await fixtureCacheInventory();
      for (final path in current.files.difference(previous.files)) {
        await File(path).delete();
      }
      for (final path in current.stages.difference(previous.stages)) {
        await Directory(path).delete(recursive: true);
      }
      final remaining = await fixtureCacheInventory();
      expect(
        remaining.files.difference(previous.files),
        isEmpty,
        reason: 'Owned export and picker copies must be removed.',
      );
      expect(
        remaining.stages.difference(previous.stages),
        isEmpty,
        reason: 'Owned export stages must be removed.',
      );
      expect(remaining.files.containsAll(previous.files), isTrue);
      expect(remaining.stages.containsAll(previous.stages), isTrue);
    });
  });

  testWidgets('native metadata identifies the installed debug app', (_) async {
    final info = await PackageInfo.fromPlatform();
    expect(info.packageName, 'com.tarkilhk.wing.dev');
    expect(info.version, isNotEmpty);
    expect(int.tryParse(info.buildNumber), greaterThan(0));
  });

  testWidgets('backup import reads selected UTF-8 file', (_) async {
    debugPrint('FILE_TRANSFER:backup-select');
    expect(await backupIo.pickBackupFile(), contents);
  });

  testWidgets('cancelled backup import returns no contents', (_) async {
    debugPrint('FILE_TRANSFER:backup-cancel');
    expect(await backupIo.pickBackupFile(), isNull);
  });

  testWidgets('document attachment provides a readable local path', (_) async {
    debugPrint('FILE_TRANSFER:document-select');
    final file = await FilePicker.pickFile(type: FileType.any);
    expect(file, isNotNull);
    expect(file!.name, 'wing-native-probe.json');
    expect(file.path, isNotNull);
    expect(await File(file.path!).readAsString(), contents);
  });

  testWidgets('photo attachment provides a readable local PNG', (_) async {
    debugPrint('FILE_TRANSFER:photo-select');
    final file = await FilePicker.pickFile(type: FileType.image);
    expect(file, isNotNull);
    expect(file!.name, 'wing-native-probe.png');
    expect(file.path, isNotNull);
    expect(await File(file.path!).readAsBytes(), await file.readAsBytes());
    expect((await file.readAsBytes()).take(8), [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]);
  });

  testWidgets('cancelled attachment selection returns no file', (_) async {
    debugPrint('FILE_TRANSFER:document-cancel');
    expect(await FilePicker.pickFile(type: FileType.any), isNull);
  });

  testWidgets('backup export opens Android sharing and handles dismissal', (
    _,
  ) async {
    final previous = await fixtureCacheInventory();
    debugPrint('FILE_TRANSFER:share-cancel');
    expect(
      await backupIo.deliverExport(contents, canDispatch: () => true),
      isNull,
    );
    final current = await fixtureCacheInventory();
    final ownedStages = current.stages.difference(previous.stages);
    expect(
      ownedStages,
      isEmpty,
      reason:
          'Android share handoff releases Wing\'s source even on dismissal.',
    );
    final exports = current.files
        .difference(previous.files)
        .map(File.new)
        .where(
          (file) =>
              file.uri.pathSegments.last.startsWith('wing-config-') &&
              !previous.files.contains(file.path),
        )
        .toList();
    expect(exports, hasLength(1));
    expect(exports.single.parent.path, endsWith('/share_plus'));
    expect(await exports.single.readAsString(), contents);
  });
}
