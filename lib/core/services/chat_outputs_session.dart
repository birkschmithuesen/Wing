import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/chat_output.dart';
import '../models/app_preferences.dart';
import 'android_file_delivery_service.dart';
import 'media_preview_service.dart';
import 'owned_remote_files.dart';
import 'profile_gateway.dart';
import 'remote_files_client.dart';
import 'remote_file_saver.dart';
import 'web_preview.dart';
import 'workspace_connection_failure.dart';

enum OutputPreviewKind { image, svg, external, html, text }

@immutable
final class OutputPreview {
  const OutputPreview({
    required this.kind,
    this.file,
    this.uri,
    this.text,
    this.canOpen = false,
    this.canPlay = false,
    this.isPdf = false,
    this.isMarkdown = false,
    this.svgSource,
  });
  final OutputPreviewKind kind;
  final RemoteFileDownload? file;
  final Uri? uri;
  final RemoteTextPreview? text;
  final bool canOpen;
  final bool canPlay;
  final bool isPdf;
  final bool isMarkdown;
  final String? svgSource;
}

@immutable
final class ChatOutputsObservation {
  ChatOutputsObservation({
    required this.hasObservation,
    required Iterable<ChatOutput> outputs,
    required this.loading,
    required this.hasMore,
    required this.error,
    required this.retryable,
    required this.retryRefresh,
  }) : outputs = List.unmodifiable(outputs);
  final List<ChatOutput> outputs;
  final bool loading;
  final bool hasObservation;
  final bool hasMore;
  final String? error;
  final bool retryable;
  final bool retryRefresh;
}

/// Captured output discovery, preparation and file-delivery policy for one route.
/// Navigation, theme, focus and rendering belong to the view.
final class ChatOutputsSession extends ChangeNotifier {
  ChatOutputsSession({
    required Future<ProfileHistoryPage> Function(int offset) loadHistory,
    required Future<RemoteFileDownload> Function(String path) download,
    required Future<RemoteTextPreview> Function(String path) readText,
    Future<void> Function(RemoteFileDownload)? deliver,
    AndroidFileDeliveryService fileDelivery =
        const AndroidFileDeliveryService(),
    MediaPreviewService mediaPreview = const MediaPreviewService(),
  }) : _readPage = loadHistory,
       _downloadFile = download,
       _previewText = readText,
       _deliver = deliver ?? shareRemoteFile,
       _viewer = fileDelivery,
       _player = mediaPreview;

  final Future<ProfileHistoryPage> Function(int) _readPage;
  final Future<RemoteFileDownload> Function(String) _downloadFile;
  final Future<RemoteTextPreview> Function(String) _previewText;
  final Future<void> Function(RemoteFileDownload) _deliver;
  final AndroidFileDeliveryService _viewer;
  final MediaPreviewService _player;
  final _outputs = <String, ChatOutput>{};
  int? _nextOffset = 0;
  bool _loading = false;
  bool _hasObservation = false;
  String? _error;
  bool _retryable = false;
  bool _retryRefresh = false;
  bool _active = true;
  int _notificationDepth = 0;

  ChatOutputsObservation get observation => ChatOutputsObservation(
    hasObservation: _hasObservation,
    outputs: _outputs.values,
    loading: _loading,
    hasMore: _nextOffset != null,
    error: _error,
    retryable: _retryable,
    retryRefresh: _retryRefresh,
  );

  Future<void> load({bool refresh = false}) async {
    if (!_active || _loading || !refresh && _nextOffset == null) return;
    final offset = refresh ? 0 : _nextOffset!;
    _loading = true;
    _error = null;
    _retryable = false;
    _notify();
    if (!_active) return;
    try {
      final page = await _readPage(offset);
      if (!_active) return;
      final outputs = extractChatOutputs(page.rows.reversed);
      if (refresh) _outputs.clear();
      for (final output in outputs) {
        _outputs.putIfAbsent(output.target, () => output);
      }
      _nextOffset = page.nextOffset;
      _hasObservation = true;
    } catch (error) {
      if (!_active) return;
      _retryable = isTemporaryWorkspaceFailure(error);
      _retryRefresh = refresh;
      _error = _outputs.isEmpty
          ? "Couldn't load this chat's files and links. Check the Hermes connection, then try again."
          : "Couldn't load more outputs. Your current results are still here. Check the Hermes connection, then try again.";
    } finally {
      if (_active) {
        _loading = false;
        _notify();
      }
    }
  }

  void _requireActive() {
    if (!_active) throw StateError('This output route is closed.');
  }

  Future<RemoteFileDownload> download(String path) async {
    _requireActive();
    final file = await _downloadFile(path);
    _requireActive();
    return file;
  }

  Future<void> share(RemoteFileDownload file) async {
    _requireActive();
    await _deliver(file);
  }

  Future<bool> save(RemoteFileDownload file) async {
    _requireActive();
    return saveRemoteFile(file);
  }

  Future<bool> open(RemoteFileDownload file, {String? mimeType}) async {
    _requireActive();
    return _viewer.openInApp(file, mimeType: mimeType);
  }

  Future<bool> play(
    RemoteFileDownload file, {
    required String title,
    String? mimeType,
    required Map<String, int> appearance,
  }) async {
    _requireActive();
    return _player.open(
      file,
      title: title,
      mimeType: mimeType,
      appearance: appearance,
    );
  }

  Future<void> openLink(String target, WebLinkDestination? destination) async {
    _requireActive();
    final uri = externalWebLink(target);
    if (uri == null ||
        destination == null ||
        !await openWebLink(uri, destination)) {
      throw StateError('Could not open link');
    }
  }

  Future<OutputPreview> prepare(ChatOutput output) async {
    _requireActive();
    final path = output.path;
    if (output.kind == ChatOutputKind.image) {
      RemoteFileDownload? file;
      Uri? uri;
      if (path == null &&
          !output.url!.startsWith('data:image/') &&
          _isSvgName(output.label, output.url!)) {
        return OutputPreview(kind: OutputPreviewKind.external);
      }
      if (path != null) {
        file = await download(path);
      } else if (output.url!.startsWith('data:image/')) {
        final data = decodeEmbeddedImage(output.url!);
        final extension =
            const {
              'image/png': 'png',
              'image/jpeg': 'jpg',
              'image/gif': 'gif',
              'image/webp': 'webp',
              'image/svg+xml': 'svg',
            }[data.mimeType] ??
            'img';
        file = RemoteFileDownload(
          filename: 'image.$extension',
          bytes: data.bytes,
        );
      } else {
        uri = externalWebLink(output.url!);
        if (uri == null) throw StateError('Invalid image link');
      }
      _requireActive();
      if (file != null && file.bytes.length > maxFilePreviewBytes) {
        throw const FormatException('Image attachment too large');
      }
      if (file != null && _isSvgName(file.filename, path ?? output.url ?? '')) {
        return OutputPreview(
          kind: OutputPreviewKind.svg,
          file: file,
          svgSource: utf8.decode(file.bytes),
        );
      }
      return OutputPreview(kind: OutputPreviewKind.image, file: file, uri: uri);
    }
    if (path == null) {
      return OutputPreview(kind: OutputPreviewKind.external);
    }
    if (_hasHtmlExtension(path) || _hasHtmlExtension(output.label)) {
      return OutputPreview(kind: OutputPreviewKind.html);
    }
    final text = await _previewText(path);
    _requireActive();
    if (_isHtmlPreview(output, text)) {
      return OutputPreview(kind: OutputPreviewKind.html);
    }
    return OutputPreview(
      kind: OutputPreviewKind.text,
      text: text,
      canOpen: _viewer.supportsType(output.label, mimeType: text.mimeType),
      canPlay: _player.supportsType(output.label, mimeType: text.mimeType),
      isPdf:
          text.mimeType.split(';').first.trim().toLowerCase() ==
              'application/pdf' ||
          output.label.toLowerCase().endsWith('.pdf'),
      isMarkdown: _isMarkdownPreview(output, text),
    );
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
    if (_notificationDepth == 0) super.dispose();
  }
}

bool _isMarkdownPreview(ChatOutput output, RemoteTextPreview preview) {
  if (preview.binary) return false;
  final language = preview.language.trim().toLowerCase();
  final mimeType = preview.mimeType.split(';').first.trim().toLowerCase();
  final label = output.label.toLowerCase();
  final path = preview.path.toLowerCase();
  return language == 'markdown' ||
      language == 'md' ||
      mimeType == 'text/markdown' ||
      label.endsWith('.md') ||
      label.endsWith('.markdown') ||
      path.endsWith('.md') ||
      path.endsWith('.markdown');
}

bool _isHtmlPreview(ChatOutput output, RemoteTextPreview preview) {
  if (preview.binary) return false;
  final mimeType = preview.mimeType.split(';').first.trim().toLowerCase();
  final label = output.label.toLowerCase();
  final path = preview.path.toLowerCase();
  return mimeType == 'text/html' ||
      label.endsWith('.html') ||
      label.endsWith('.htm') ||
      path.endsWith('.html') ||
      path.endsWith('.htm');
}

bool _hasHtmlExtension(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.html') || lower.endsWith('.htm');
}

bool _isSvgName(String filename, String target) =>
    filename.toLowerCase().endsWith('.svg') ||
    Uri.tryParse(target)?.path.toLowerCase().endsWith('.svg') == true;
