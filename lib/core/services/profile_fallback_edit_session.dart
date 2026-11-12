import 'package:wing/core/models/settings_edit.dart';
import 'package:flutter/foundation.dart';

import '../models/fallback_model.dart';
import '../models/model_choice.dart';
import 'administration_repository.dart';

/// A review is bound to one pending edit and one fresh remote observation.
class FallbackChangeReview {
  FallbackChangeReview._(
    this.current,
    this.pending,
    this._baseline,
    this._revision,
  );
  final List<FallbackModel> current;
  final List<FallbackModel> pending;
  final Object? _baseline;
  final int _revision;
}

class FallbackSelectionDraft {
  FallbackSelectionDraft._(
    List<ModelChoice> choices,
    this.current,
    this._rows,
    this._revision,
    this._index,
  ) : choices = List.unmodifiable(choices);
  final List<ModelChoice> choices;
  final FallbackModel? current;
  final List<FallbackModel> _rows;
  final int _revision;
  final int? _index;
}

class ProfileFallbackEditSession extends ChangeNotifier {
  ProfileFallbackEditSession(this.profile);
  final ProfileAdministration profile;
  List<FallbackModel>? _rows;
  List<FallbackModel>? _pending;
  Object? _baseline;
  bool _busy = false;
  bool _conflict = false;
  bool _disposed = false;
  int _generation = 0;
  int _revision = 0;
  String? _error;

  List<FallbackModel>? get rows => _rows;
  List<FallbackModel>? get pending => _pending;
  bool get busy => _busy;
  bool get conflict => _conflict;
  String? get error => _error;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _owns(int generation) => !_disposed && generation == _generation;
  Object _value(Map<String, dynamic> config) => List.unmodifiable(
    FallbackModel.fromConfig(config).map((row) => row.toWire()),
  );

  Future<void> load() async {
    if (_disposed || _busy) return;
    final generation = ++_generation;
    try {
      final config = await profile.config();
      final rows = FallbackModel.fromConfig(config);
      if (!_owns(generation)) return;
      _rows = rows;
      if (_pending == null) _baseline = _value(config);
      _error = null;
    } catch (failure) {
      if (_owns(generation)) _error = administrationError(failure);
    }
    if (_owns(generation)) _changed();
  }

  Future<List<ModelChoice>> catalog({bool refresh = false}) async {
    if (_disposed) throw StateError('Fallback edit is closed');
    final generation = _generation;
    try {
      final choices = (await profile.modelCatalog.load(
        explicitOnly: true,
        refresh: refresh,
      )).choices;
      if (!_owns(generation)) throw StateError('Fallback edit was superseded');
      return List.unmodifiable(choices);
    } catch (_) {
      if (_owns(generation)) {
        _error = 'Current model choices could not be loaded. Retry.';
        _changed();
      }
      rethrow;
    }
  }

  Future<FallbackSelectionDraft?> prepareSelection({int? index}) async {
    if (_disposed || _busy || _rows == null) return null;
    final rows = _rows!;
    final revision = _revision;
    final current = index == null ? null : rows[index];
    try {
      final choices = await catalog();
      if (_disposed ||
          _busy ||
          !identical(rows, _rows) ||
          revision != _revision) {
        return null;
      }
      return FallbackSelectionDraft._(choices, current, rows, revision, index);
    } catch (_) {
      return null;
    }
  }

  Future<void> select(
    ModelChoice choice, {
    required FallbackSelectionDraft draft,
  }) async {
    if (_disposed || _busy || _rows == null) return;
    if (!identical(draft._rows, _rows) || draft._revision != _revision) {
      _error = 'The fallback list changed. Choose the model again.';
      _changed();
      return;
    }
    final index = draft._index;
    final next = [..._rows!];
    if (index == null) {
      next.add(
        FallbackModel.fromWire({
          'provider': choice.provider,
          'model': choice.model,
        }),
      );
    } else {
      next[index] = next[index].withSelection(choice.provider, choice.model);
    }
    await _save(next);
  }

  Future<void> remove(int index) async {
    if (_disposed || _busy || _rows == null) return;
    final next = [..._rows!]..removeAt(index);
    await _save(next);
  }

  Future<void> move(int index, {required bool up}) async {
    if (_disposed || _busy || _rows == null) return;
    final next = [..._rows!];
    final row = next.removeAt(index);
    next.insert(index + (up ? -1 : 1), row);
    await _save(next);
  }

  Future<void> retry() async {
    if (_pending == null || _conflict || _disposed || _busy) return;
    await _save(_pending!, newIntent: false);
  }

  Future<void> _save(List<FallbackModel> next, {bool newIntent = true}) async {
    if (newIntent) {
      _baseline = List.unmodifiable(_rows!.map((row) => row.toWire()));
    }
    final generation = ++_generation;
    _revision++;
    var dispatchActive = true;
    var dispatched = false;
    bool canDispatch() => dispatchActive && _owns(generation);
    _busy = true;
    _error = null;
    _pending = List.unmodifiable(next);
    _changed();
    try {
      final latest = await profile.config();
      if (!_owns(generation)) return;
      // Stock does not offer an atomic expected-version condition. This fresh
      // client preflight detects observed conflicts, not all concurrent writes.
      if (!sameSetting(_value(latest), _baseline)) {
        _conflict = true;
        throw const AdministrationFailure(
          'Fallback models changed elsewhere. Review the current and pending lists before applying.',
        );
      }
      final wire = next.map((row) => row.toWire()).toList();
      await profile.requireProfile();
      if (!_owns(generation)) return;
      final result = await profile.server.ownedMutation(
        'PUT',
        'config',
        {'profile': profile.name},
        {
          'config': {'fallback_providers': wire},
          'profile': profile.name,
        },
        canDispatch,
        () => dispatched = true,
      );
      if (result['ok'] != true) {
        throw const AdministrationFailure(
          'Fallback save was not acknowledged.',
        );
      }
      final saved = await profile.config();
      if (!_owns(generation)) return;
      if (!sameSetting(_value(saved), wire)) {
        throw const AdministrationFailure(
          'Save not confirmed. Your edits are kept. Refresh before retrying.',
        );
      }
      if (!_owns(generation)) return;
      _rows = List.unmodifiable(next);
      _baseline = wire;
      _pending = null;
      _conflict = false;
    } catch (failure) {
      if (_owns(generation)) {
        _error = !dispatched && failure is FormatException
            ? 'Current fallback settings could not be confirmed. Your edits are kept; refresh before saving.'
            : dispatched || _conflict
            ? administrationError(failure, writing: true)
            : 'The fallback change was not sent. Your edits are kept. Try again.';
      }
    } finally {
      dispatchActive = false;
      if (_owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  Future<FallbackChangeReview?> reviewPending() async {
    if (_disposed || _busy || _pending == null) return null;
    final generation = ++_generation;
    try {
      final config = await profile.config();
      final current = FallbackModel.fromConfig(config);
      if (!_owns(generation)) return null;
      _rows = current;
      _error = null;
      _changed();
      return FallbackChangeReview._(
        current,
        _pending!,
        _value(config),
        _revision,
      );
    } catch (failure) {
      if (_owns(generation)) {
        _error = administrationError(failure);
        _changed();
      }
      return null;
    }
  }

  Future<void> applyReviewed(FallbackChangeReview review) async {
    if (_disposed ||
        _busy ||
        review._revision != _revision ||
        !identical(review.pending, _pending)) {
      return;
    }
    _baseline = review._baseline;
    await _save(review.pending, newIntent: false);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
