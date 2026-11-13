import 'package:flutter/services.dart';

import 'remote_files_client.dart';

/// Hands an already authenticated download to an installed Android viewer.
class AndroidFileDeliveryService {
  static const channelName = 'com.tarkilhk.wing/file_delivery';
  static const _maxBytes = maxFilePreviewBytes;

  final MethodChannel _channel;

  const AndroidFileDeliveryService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  bool supportsType(String filename, {String? mimeType}) =>
      resolveFileMimeType(filename, mimeType: mimeType) != null;

  /// Returns false when this file is unsupported or Android has no viewer.
  Future<bool> openInApp(RemoteFileDownload file, {String? mimeType}) async {
    final resolved = resolveFileMimeType(file.filename, mimeType: mimeType);
    if (resolved == null) {
      return false;
    }
    if (file.bytes.isEmpty || file.bytes.length > _maxBytes) {
      throw StateError('This file could not be opened on this device.');
    }
    try {
      return await _channel.invokeMethod<bool>('openInApp', {
            'filename': file.filename,
            'mimeType': resolved,
            'bytes': file.bytes,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      throw StateError('This file could not be opened on this device.');
    }
  }
}

String? resolveFileMimeType(String filename, {String? mimeType}) {
  final normalized = mimeType?.split(';').first.trim().toLowerCase();
  if (normalized != null && _supportedMimeTypes.contains(normalized)) {
    return normalized;
  }
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) {
    return null;
  }
  return _mimeByExtension[filename.substring(dot + 1).toLowerCase()];
}

const _mimeByExtension = <String, String>{
  'pdf': 'application/pdf',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'm4a': 'audio/mp4',
  'mp3': 'audio/mpeg',
  'oga': 'audio/ogg',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
  'weba': 'audio/webm',
  'avi': 'video/x-msvideo',
  'm4v': 'video/mp4',
  'mkv': 'video/x-matroska',
  'mov': 'video/quicktime',
  'mp4': 'video/mp4',
  'mpeg': 'video/mpeg',
  'mpg': 'video/mpeg',
  'webm': 'video/webm',
};

const _supportedMimeTypes = <String>{
  'application/pdf',
  'audio/aac',
  'audio/flac',
  'audio/mp4',
  'audio/mpeg',
  'audio/ogg',
  'audio/wav',
  'audio/webm',
  'audio/x-wav',
  'video/mp4',
  'video/mpeg',
  'video/quicktime',
  'video/webm',
  'video/x-matroska',
  'video/x-msvideo',
};
