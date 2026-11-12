import 'package:flutter/foundation.dart';

import '../models/server_reference.dart';
import 'server_files_repository.dart';

/// A filesystem-browser visit, backed by the same managed files owner as @.
final class ServerFilesBrowser extends ChangeNotifier {
  factory ServerFilesBrowser({
    required ServerFilesRepository files,
    required bool Function() isCurrent,
  }) => ServerFilesBrowser._(files, isCurrent);

  ServerFilesBrowser._(this._files, this._isCurrent);

  final ServerFilesRepository _files;
  final bool Function() _isCurrent;
  ServerReferenceDirectory? _directory;
  ServerReferenceDirectory? get directory => _directory;
  List<ServerReferenceEntry> get folders => List.unmodifiable(
    _directory?.entries.where((entry) => entry.directory) ?? const [],
  );
  bool _loading = false;
  bool _creating = false;
  bool get busy => _loading || _creating;
  bool get creating => _creating;
  bool get canCreate =>
      !busy && _active && _directory != null && _files.write != null;
  bool get canSelect => !busy && _directory != null && _active;
  String? _requested;
  String? get displayedPath => _loading ? _requested : _directory?.path;
  String? _error;
  String? get error => _error;
  int _generation = 0;
  bool _disposed = false;
  bool get _active => !_disposed && _isCurrent();
  String? _retryPath;

  Future<void> open([String? path]) => _creating ? Future.value() : _load(path);

  Future<void> _load(String? path) async {
    if (!_active) return;
    final generation = ++_generation;
    _requested = path;
    _retryPath = path;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final listing = await _files.directory(path);
      if (!_active || generation != _generation) return;
      _directory = listing;
    } catch (_) {
      if (!_active || generation != _generation) return;
      _error = 'Could not open this folder. Check access and try again.';
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() => open(_directory?.path);
  Future<void> retry() => open(_retryPath);
  Future<void> up() async {
    final parent = _directory?.parent;
    if (parent != null && !busy) await open(parent);
  }

  Future<bool> createFolder(String name) async {
    final directory = _directory;
    if (!canCreate || directory == null) return false;
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        ServerReferencePath.pathContext.basename(trimmed) != trimmed ||
        trimmed.contains('\\')) {
      _error = 'Enter a folder name without path separators.';
      notifyListeners();
      return false;
    }
    _creating = true;
    _error = null;
    notifyListeners();
    try {
      final path = ServerReferencePath.pathContext.join(
        directory.path,
        trimmed,
      );
      final confirmed = await _files.createDirectory(
        path,
        canDispatch: () => _active,
      );
      if (!_active) return false;
      await _load(confirmed);
      return _active && _error == null;
    } catch (error) {
      if (_active) {
        _error = error is StateError
            ? error.message.toString()
            : 'Could not create this folder. Check access and try again.';
      }
      return false;
    } finally {
      if (!_disposed) {
        _creating = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
