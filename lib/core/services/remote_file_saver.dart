import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

import 'remote_files_client.dart';
import 'platform_share.dart';

/// Saves authenticated bytes through Android's document destination picker.
/// A cancelled picker is not a failure and must not report a successful save.
Future<bool> saveRemoteFile(RemoteFileDownload file) async {
  final destination = await FilePicker.saveFile(
    fileName: file.filename,
    bytes: file.bytes,
  );
  return destination != null;
}

/// Shares authenticated bytes using the platform share sheet.
Future<void> shareRemoteFile(RemoteFileDownload download) async {
  final directory = await (await getTemporaryDirectory()).createTemp(
    'hermes-output-',
  );
  var dispatched = false;
  try {
    final file = File('${directory.path}/${download.filename}');
    await file.writeAsBytes(download.bytes, flush: true);
    await platformShare(
      ShareParams(files: [XFile(file.path)]),
      onDispatched: () => dispatched = true,
    );
  } finally {
    // share_plus 13.3.0 copies Android inputs into its own provider cache before
    // presenting the chooser. Release only Wing's staging directory here.
    if (!dispatched || Platform.isAndroid) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // The operating system may already have removed temporary storage.
      }
    }
  }
}
