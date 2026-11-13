import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'file_open_error_message.dart';
import 'remote_files_client.dart';
import 'remote_file_saver.dart';
import 'web_preview.dart';

/// Binds requests and their transport lifetime to the chat that exposed them.
final class OwnedRemoteFiles {
  OwnedRemoteFiles({
    required this._source,
    required this.profileName,
    required this.storedSessionId,
    required this._release,
  });

  final RemoteFilesDataSource _source;
  final void Function() _release;
  final String profileName;
  final String storedSessionId;
  bool _active = true;

  void _requireActive() {
    if (!_active) throw StateError('This file owner is closed.');
  }

  Future<RemoteTextPreview> readText(String path) async {
    _requireActive();
    final preview = await _source.readText(
      path,
      profileName: profileName,
      storedSessionId: storedSessionId,
    );
    _requireActive();
    return preview;
  }

  Future<RemoteFileDownload> download(String path) async {
    _requireActive();
    final file = await _source.download(
      path,
      profileName: profileName,
      storedSessionId: storedSessionId,
    );
    _requireActive();
    return file;
  }

  Future<bool> downloadAndSave(
    String path, {
    required bool Function() admitPresentation,
  }) async {
    final file = await download(path);
    if (!_active || !admitPresentation()) return false;
    return saveRemoteFile(file);
  }

  Future<void> downloadAndShare(
    String path, {
    required bool Function() admitPresentation,
    Future<void> Function(RemoteFileDownload) deliver = shareRemoteFile,
  }) async {
    final file = await download(path);
    if (!_active || !admitPresentation()) return;
    await deliver(file);
  }

  void dispose() {
    if (!_active) return;
    _active = false;
    _release();
  }
}

/// An acquired original image. Flutter providers and thumbnail geometry are UI.
@immutable
final class ImageResource {
  ImageResource.bytes(List<int> value)
    : bytes = Uint8List.fromList(value).asUnmodifiableView(),
      uri = null;
  const ImageResource.uri(Uri value) : uri = value, bytes = null;

  final Uint8List? bytes;
  final Uri? uri;
}

/// Address admission and embedded-byte budget shared by attachment previews.
/// Remote paths are always loaded by their captured owner, never as device files.
Future<ImageResource> acquireConversationImage(
  String target,
  Future<Uint8List> Function(String)? loadRemote,
) => _acquireImageResource(
  target,
  loadRemote: loadRemote,
  allowEmbedded: false,
  allowWindowsPaths: true,
);

/// Actual tool image parts may contain embedded pixels. Other locators retain
/// the conversation admission policy and captured remote-file owner.
Future<ImageResource> acquireToolReceiptImage(
  String target,
  Future<Uint8List> Function(String)? loadRemote,
) => target.startsWith('data:')
    ? _acquireImageResource(
        target,
        loadRemote: loadRemote,
        allowEmbedded: true,
        allowWindowsPaths: false,
      )
    : acquireConversationImage(target, loadRemote);

Future<ImageResource> acquireUserAttachmentImage(
  String target,
  Future<Uint8List> Function(String)? loadRemote,
) => _acquireImageResource(
  target,
  loadRemote: loadRemote,
  allowEmbedded: true,
  allowWindowsPaths: false,
);

/// Admits raw and normalized URI text before parsing or copying its payload.
/// UriData can expand a Unicode character to nine percent-encoded characters;
/// its temporary normalized representation shares the 45 MiB text budget.
({String mimeType, Uint8List bytes}) decodeEmbeddedImage(String target) {
  const encodedLimit = 45 * 1024 * 1024;
  if (target.length > encodedLimit) {
    throw const FormatException('Image attachment too large');
  }
  final comma = target.indexOf(',');
  if (comma >= 0 && !(comma >= 7 && target.startsWith(';base64', comma - 7))) {
    _admitPercentImageContent(target, comma + 1, encodedLimit);
  }
  final data = UriData.parse(target);
  if (!data.mimeType.startsWith('image/')) {
    throw const FormatException('Invalid image attachment');
  }
  final content = data.contentText;
  if (content.length + comma + 1 > encodedLimit) {
    throw const FormatException('Image attachment too large');
  }
  var decodedLength = content.length;
  if (data.isBase64) {
    decodedLength = content.length ~/ 4 * 3;
    if (content.endsWith('==')) {
      decodedLength -= 2;
    } else if (content.endsWith('=')) {
      decodedLength--;
    }
  } else {
    for (var index = 0; index < content.length; index++) {
      if (content.codeUnitAt(index) == 0x25) {
        decodedLength -= 2;
        index += 2;
      }
    }
  }
  if (decodedLength > maxFilePreviewBytes) {
    throw const FormatException('Image attachment too large');
  }
  return (mimeType: data.mimeType, bytes: data.contentAsBytes());
}

// Count URI normalization and decoded bytes without allocating either. Keep
// UriData responsible for syntax and decoding; these counts follow its RFC 2396
// literal characters, RFC 3986 unreserved escapes and UTF-8 percent encoding.
void _admitPercentImageContent(String target, int start, int encodedLimit) {
  var encoded = start;
  var decoded = 0;
  for (var index = start; index < target.length; index++) {
    final code = target.codeUnitAt(index);
    var byteCount = 1;
    var textCount = 1;
    if (code == 0x25) {
      final high = index + 2 < target.length
          ? _hexImageDigit(target.codeUnitAt(index + 1))
          : -1;
      final low = index + 2 < target.length
          ? _hexImageDigit(target.codeUnitAt(index + 2))
          : -1;
      if (high >= 0 && low >= 0) {
        textCount = _unreservedImageChar(high * 16 + low) ? 1 : 3;
        index += 2;
      } else {
        textCount = 3; // UriData escapes a literal invalid percent as %25.
      }
    } else if (code >= 0x80) {
      byteCount = code <= 0x7ff ? 2 : 3;
      if (code >= 0xd800 && code <= 0xdbff && index + 1 < target.length) {
        final tail = target.codeUnitAt(index + 1);
        if (tail >= 0xdc00 && tail <= 0xdfff) {
          byteCount = 4;
          index++;
        }
      }
      textCount = byteCount * 3;
    } else if (!_unreservedImageChar(code) &&
        !switch (code) {
          0x21 ||
          0x24 ||
          0x26 ||
          0x27 ||
          0x28 ||
          0x29 ||
          0x2a ||
          0x2b ||
          0x2c ||
          0x2f ||
          0x3a ||
          0x3b ||
          0x3d ||
          0x3f ||
          0x40 => true,
          _ => false,
        }) {
      textCount = 3;
    }
    encoded += textCount;
    decoded += byteCount;
    if (encoded > encodedLimit || decoded > maxFilePreviewBytes) {
      throw const FormatException('Image attachment too large');
    }
  }
}

bool _unreservedImageChar(int code) =>
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    switch (code) {
      0x2d || 0x2e || 0x5f || 0x7e => true,
      _ => false,
    };

int _hexImageDigit(int code) => code >= 0x30 && code <= 0x39
    ? code - 0x30
    : code >= 0x41 && code <= 0x46
    ? code - 0x41 + 10
    : code >= 0x61 && code <= 0x66
    ? code - 0x61 + 10
    : -1;

Future<ImageResource> _acquireImageResource(
  String target, {
  required Future<Uint8List> Function(String)? loadRemote,
  required bool allowEmbedded,
  required bool allowWindowsPaths,
}) async {
  if (allowEmbedded && target.length > 45 * 1024 * 1024) {
    throw const FormatException('Image attachment too large');
  }
  if (target.length >= 5 && target.substring(0, 5).toLowerCase() == 'data:') {
    if (!allowEmbedded) throw const FormatException('Image unavailable');
    return ImageResource.bytes(decodeEmbeddedImage(target).bytes);
  }
  final uri = Uri.tryParse(target);
  final external =
      allowEmbedded &&
          uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty
      ? uri
      : externalWebLink(target);
  if (external != null) return ImageResource.uri(external);
  if (allowEmbedded && uri == null ||
      uri?.hasScheme == true &&
          !(allowWindowsPaths && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(target)) ||
      loadRemote == null) {
    throw const FormatException('Image unavailable');
  }
  final bytes = await loadRemote(target);
  if (bytes.length > maxFilePreviewBytes) {
    throw const FormatException('Image attachment too large');
  }
  return ImageResource.bytes(bytes);
}

@immutable
final class HtmlPreviewObservation {
  const HtmlPreviewObservation({
    required this.source,
    required this.error,
    required this.loading,
    required this.sharing,
    required this.hasFile,
  });
  final String? source;
  final String? error;
  final bool loading;
  final bool sharing;
  final bool hasFile;
}

/// One route's complete original HTML, decode decision and sharing operation.
/// The source is never populated from a truncated text preview.
final class HtmlPreviewReader extends ChangeNotifier {
  HtmlPreviewReader({required this._download, required this._share});

  final Future<RemoteFileDownload> Function() _download;
  final Future<void> Function(RemoteFileDownload) _share;
  RemoteFileDownload? _file;
  String? _source;
  String? _error;
  bool _loading = false;
  bool _sharing = false;
  bool _active = true;
  int _notificationDepth = 0;

  HtmlPreviewObservation get observation => HtmlPreviewObservation(
    source: _source,
    error: _error,
    loading: _loading,
    sharing: _sharing,
    hasFile: _file != null,
  );

  Future<void> load() async {
    if (!_active || _loading || _file != null) return;
    _loading = true;
    _error = null;
    _notify();
    if (!_active) return;
    try {
      final file = await _download();
      if (!_active) return;
      _file = file;
      if (file.bytes.length > maxFilePreviewBytes) {
        _error =
            'This HTML file is too large to preview. Use Save or share to open it in another app.';
      } else {
        try {
          _source = utf8.decode(file.bytes);
        } on FormatException {
          _error =
              "This HTML file can't be read here. Use Save or share to open it in another app.";
        }
      }
    } catch (error) {
      if (_active) _error = fileOpenErrorMessage(error);
    } finally {
      if (_active) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<String?> share() async {
    final file = _file;
    if (!_active || _sharing || file == null) return null;
    _sharing = true;
    _notify();
    if (!_active) return null;
    try {
      await _share(file);
      return null;
    } catch (error) {
      return _active ? fileOpenErrorMessage(error) : null;
    } finally {
      if (_active) {
        _sharing = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_active) return;
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (!_active && _notificationDepth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (!_active) return;
    _active = false;
    _file = null;
    _source = null;
    if (_notificationDepth == 0) super.dispose();
  }
}
