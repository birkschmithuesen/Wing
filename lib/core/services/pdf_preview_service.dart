import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_files_client.dart';

class PdfDocument {
  final String id;
  final int pageCount;

  const PdfDocument(this.id, this.pageCount);
}

/// Temporary native PDF resources, released when the reader closes.
class PdfPreviewService {
  static const channelName = 'com.tarkilhk.wing/pdf_preview';
  final MethodChannel _channel;

  const PdfPreviewService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  PdfPreviewReader createReader(
    Future<RemoteFileDownload> Function() download,
  ) => PdfPreviewReader._(this, download);

  Future<PdfDocument> open(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxFilePreviewBytes) {
      throw StateError('This PDF could not be displayed.');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('open', {
        'bytes': bytes,
      });
      final id = result?['documentId'];
      final pages = result?['pageCount'];
      if (id is String && id.isNotEmpty) {
        if (pages is int && pages > 0) return PdfDocument(id, pages);
        await close(PdfDocument(id, 0));
      }
    } on PlatformException {
      // Native decoder errors can contain paths or document details.
    } on MissingPluginException {
      // External viewers remain available on unsupported platforms.
    }
    throw StateError('This PDF could not be displayed.');
  }

  Future<Uint8List> render(PdfDocument document, int page) async {
    if (page < 0 || page >= document.pageCount) {
      throw ArgumentError('Invalid PDF page');
    }
    try {
      final image = await _channel.invokeMethod<Uint8List>('render', {
        'documentId': document.id,
        'page': page,
      });
      if (image != null && image.isNotEmpty) return image;
    } on PlatformException {
      // Keep native exceptions out of the user-facing error.
    } on MissingPluginException {
      // The caller retains the downloaded PDF and external-viewer option.
    }
    throw StateError('This PDF page could not be displayed.');
  }

  Future<void> close(PdfDocument document) async {
    try {
      await _channel.invokeMethod<void>('close', {'documentId': document.id});
    } on PlatformException {
      // Disposal is best effort after the route or engine has closed.
    } on MissingPluginException {
      // The native engine may already have released its resources.
    }
  }
}

@immutable
final class PdfPreviewObservation {
  const PdfPreviewObservation({
    required this.page,
    required this.pageCount,
    required this.pageImage,
    required this.loading,
    required this.error,
  });
  final int page;
  final int? pageCount;
  final Uint8List? pageImage;
  final bool loading;
  final String? error;
}

/// A route lease owns the native document until its last decode settles.
/// One page image is retained; complete download bytes are released after open.
final class PdfPreviewReader extends ChangeNotifier {
  PdfPreviewReader._(this._service, this._download);

  final PdfPreviewService _service;
  final Future<RemoteFileDownload> Function() _download;
  RemoteFileDownload? _file;
  PdfDocument? _document;
  Uint8List? _pageImage;
  int _page = 0;
  bool _loading = false;
  bool _active = true;
  int _notificationDepth = 0;
  String? _error;

  PdfPreviewObservation get observation => PdfPreviewObservation(
    page: _page,
    pageCount: _document?.pageCount,
    pageImage: _pageImage,
    loading: _loading,
    error: _error,
  );

  Future<void> load() => showPage(_page);

  Future<void> showPage(int page) async {
    if (!_active || _loading || page < 0) return;
    final count = _document?.pageCount;
    if (count != null && page >= count) return;
    if (count == null && page != 0) return;
    _page = page;
    _pageImage = null;
    _error = null;
    _loading = true;
    _notify();
    try {
      if (!_active) return;
      if (_document == null) {
        _file ??= await _download();
        if (!_active) return;
        final document = await _service.open(_file!.bytes);
        _document = document;
        _file = null;
        if (!_active) return;
      }
      final image = await _service.render(_document!, page);
      if (_active) {
        _pageImage = Uint8List.fromList(image).asUnmodifiableView();
      }
    } catch (error) {
      if (_active) {
        _error =
            'This PDF could not be displayed. Go back to open it in '
            'another app, or save/share it.';
      }
    } finally {
      _loading = false;
      if (_active) {
        _notify();
      } else {
        _file = null;
        unawaited(_releaseDocument());
      }
    }
  }

  Future<void> _releaseDocument() async {
    final document = _document;
    _document = null;
    if (document == null) return;
    try {
      await _service.close(document);
    } catch (_) {
      // A route's best-effort release must not become an unhandled UI error.
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
    _pageImage = null;
    if (!_loading) unawaited(_releaseDocument());
    if (_notificationDepth == 0) super.dispose();
  }
}
