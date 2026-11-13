import 'package:flutter/foundation.dart';
import '../models/git_review.dart';
import 'administration_repository.dart';

/// One conversation's read-only host Git review. It never mutates the repository.
class GitReviewSession extends ChangeNotifier {
  GitReviewSession({required this.server, required this.resolveWorkspace}) {
    server.retain();
  }
  final AdministrationRepository server;
  final Future<String> Function() resolveWorkspace;
  String? _workspace;
  String? get workspace => _workspace;
  List<GitReviewFile> _files = const [];
  List<GitReviewFile> get files => _files;
  GitReviewFile? _selected;
  GitReviewFile? get selected => _selected;
  GitReviewComparison _comparison = GitReviewComparison.all;
  GitReviewComparison get comparison => _comparison;
  GitReviewDiff? _diff;
  GitReviewDiff? get diff => _diff;
  bool _loading = false, _closed = false, _observed = false;
  bool get loading => _loading;
  bool get observed => _observed;
  String? _error;
  String? get error => _error;
  int _generation = 0;
  bool _owns(int generation) => !_closed && generation == _generation;

  Future<void> refresh() async {
    if (_closed || _loading) return;
    final generation = ++_generation;
    _loading = true;
    _selected = null;
    _diff = null;
    _error = null;
    notifyListeners();
    try {
      final workspace = await resolveWorkspace();
      if (!_owns(generation)) return;
      final result = await server.read('git/review/list', {
        'path': workspace,
        'scope': 'uncommitted',
      });
      final files = GitReviewFile.decode(result);
      if (!_owns(generation)) return;
      _workspace = workspace;
      _files = files;
      _observed = true;
    } catch (failure) {
      if (_owns(generation)) {
        _error = failure is StateError
            ? failure.message.toString()
            : 'Changed files could not load. Check the workspace connection and refresh.';
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> open(
    GitReviewFile file, {
    GitReviewComparison comparison = GitReviewComparison.all,
  }) async {
    if (_closed ||
        _workspace == null ||
        !_files.contains(file) ||
        comparison == GitReviewComparison.staged && !file.staged) {
      return;
    }
    if (_loading && identical(_selected, file) && _comparison == comparison) {
      return;
    }
    final generation = ++_generation;
    _selected = file;
    _comparison = comparison;
    _diff = null;
    _error = null;
    _loading = true;
    notifyListeners();
    try {
      final workspace = await resolveWorkspace();
      if (!_owns(generation)) return;
      if (workspace != _workspace) {
        throw StateError(
          'The workspace changed. Return to changed files and refresh.',
        );
      }
      final result = await server.read(
        comparison == GitReviewComparison.staged
            ? 'git/review/diff'
            : 'git/file-diff',
        {
          'path': workspace,
          'file': file.path,
          if (comparison == GitReviewComparison.staged) ...{
            'scope': 'uncommitted',
            'staged': 'true',
          },
        },
      );
      final text = result['diff'];
      if (text is! String) throw const FormatException('Missing Git diff');
      if (!_owns(generation)) return;
      _diff = GitReviewDiff(text);
    } catch (_) {
      if (_owns(generation)) {
        _error =
            'This diff could not load. Retry, or refresh the changed files.';
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void showFiles() {
    if (_closed) return;
    _generation++;
    _selected = null;
    _diff = null;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    server.release();
    super.dispose();
  }
}
