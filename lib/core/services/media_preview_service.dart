import 'package:flutter/services.dart';

import 'android_file_delivery_service.dart';
import 'remote_files_client.dart';

/// Plays an authenticated audio or video download in the native media viewer.
class MediaPreviewService {
  static const channelName = 'com.tarkilhk.wing/media_preview';
  static const maxBytes = maxFilePreviewBytes;

  final MethodChannel _channel;

  const MediaPreviewService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  bool supportsType(String filename, {String? mimeType}) {
    final resolved = resolveFileMimeType(filename, mimeType: mimeType);
    return resolved?.startsWith('audio/') == true ||
        resolved?.startsWith('video/') == true;
  }

  Future<bool> open(
    RemoteFileDownload file, {
    required String title,
    String? mimeType,
    Map<String, int>? appearance,
  }) async {
    final resolved = resolveFileMimeType(file.filename, mimeType: mimeType);
    if (resolved == null ||
        (!resolved.startsWith('audio/') && !resolved.startsWith('video/'))) {
      return false;
    }
    if (file.bytes.isEmpty || file.bytes.length > maxBytes) {
      throw StateError('This media could not be played on this device.');
    }
    try {
      return await _channel.invokeMethod<bool>('open', {
            'bytes': file.bytes,
            'title': title,
            'mimeType': resolved,
            'appearance': ?appearance,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      throw StateError('This media could not be played on this device.');
    }
  }
}
