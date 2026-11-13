import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'config_backup.dart';
import 'platform_share.dart';

/// Platform-facing half of the backup feature: picking files, writing the
/// export, and handing it to the share sheet.
///
/// Storage and codec sequencing belong to BackupSession. This adapter cannot
/// read or write saved connections or app preferences.
class ConfigBackupIo {
  Future<String> appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      // An unavailable package label does not change the configuration format.
      return 'unknown';
    }
  }

  /// Writes the backup to a temp file and offers it to the share
  /// sheet. Returns the file name, or null when the user dismisses the sheet.
  Future<String?> deliverExport(
    String contents, {
    required bool Function() canDispatch,
  }) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final directory = await getTemporaryDirectory();
    if (!canDispatch()) return null;

    // Each pending offer owns a distinct stage so overlapping native reads
    // cannot overwrite one another's source.
    Directory? stage;
    var dispatched = false;
    try {
      stage = await directory.createTemp('wing-backup-');
      if (!canDispatch()) return null;
      // Android's provider cache keeps only the source basename. Include this
      // offer's unique stage ID so distinct exports cannot share a filename.
      final offerId = stage.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last
          .substring('wing-backup-'.length);
      final file = File('${stage.path}/wing-config-$stamp-$offerId.json');
      await file.writeAsString(contents, flush: true);
      if (!canDispatch()) return null;

      // Admission is the share API call. The plugin owns its ensuing native
      // preparation and chooser work; route closure cannot revoke that offer.
      final result = await platformShare(
        ShareParams(
          subject: 'Wing configuration backup',
          files: <XFile>[XFile(file.path, mimeType: 'application/json')],
        ),
        onDispatched: () => dispatched = true,
      );
      if (result.status == ShareResultStatus.dismissed) return null;
      return file.uri.pathSegments.last;
    } on PlatformShareBusy catch (error) {
      throw ConfigBackupException(error.message);
    } finally {
      // share_plus 13.3.0 copies Android sources into its own provider cache
      // before presenting the chooser. Delete only Wing's original after the
      // native operation settles; recipients retain the plugin-owned copy.
      if (stage != null &&
          (!dispatched || defaultTargetPlatform == TargetPlatform.android)) {
        try {
          await stage.delete(recursive: true);
        } on FileSystemException {
          // Temporary storage may already have been removed by the OS.
        }
      }
    }
  }

  Future<String?> pickBackupFile() async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null) return null;

    return readBackupStream(picked.readAsByteStream());
  }

  /// Counts actual streamed bytes; provider-reported lengths are not trusted.
  static Future<String> readBackupStream(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in stream) {
      count += chunk.length;
      if (count > ConfigBackupLimits.maxBytes) {
        throw const ConfigBackupException(
          'This backup exceeds the 2 MiB limit.',
        );
      }
      bytes.add(chunk);
    }
    try {
      return utf8.decode(bytes.takeBytes());
    } on FormatException {
      throw const ConfigBackupException('This file is not a UTF-8 backup.');
    }
  }
}
