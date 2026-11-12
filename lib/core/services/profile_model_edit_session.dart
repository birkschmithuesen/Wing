import 'package:wing/core/models/model_catalog.dart';
import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import 'profile_gateway.dart';

enum ProfileModelSaveOutcome { saved, cancelled, retired, failed }

enum ProfileModelReviewDecision { keepMine, useServer }

enum ProfileModelReviewOutcome { applied, cancelled, retired }

/// An observation bound to this route and its still-pending choice.
/// Reviewing does not change the baseline or send a mutation.
class ProfileModelChangeReview {
  const ProfileModelChangeReview._(
    this.current,
    this.wanted,
    this._generation,
    this._revision,
    this._reviewGeneration,
  );

  final ConfiguredModel current;
  final ModelChoice wanted;
  final int _generation;
  final int _revision;
  final int _reviewGeneration;

  String get currentLabel => current.model.isEmpty
      ? 'No default model'
      : current.provider.isEmpty
      ? 'Automatic provider / ${current.model}'
      : '${current.provider} / ${current.model}';
  String get wantedLabel => '${wanted.provider} / ${wanted.model}';
}

typedef ConfirmProfileModel = Future<bool> Function(String message);

/// One route's captured profile and model edit. Disposing retires callbacks,
/// but cannot undo a mutation already delivered to stock Hermes.
class ProfileModelEditSession extends ChangeNotifier {
  ProfileModelEditSession(this._gateway);

  final ProfileGateway _gateway;
  List<ModelChoice> _choices = const [];
  ModelChoice? _saved;
  ConfiguredModel? _openingModel;
  ModelChoice? _selected;
  bool _loading = true;
  bool _saving = false;
  bool _disposed = false;
  bool _needsReview = false;
  bool _reviewing = false;
  int _revision = 0;
  int _reviewGeneration = 0;
  ProfileModelChangeReview? _activeReview;
  int _generation = 0;
  int _catalogGeneration = 0;
  String? _error;
  String? _notice;

  String get profileName => _gateway.scope.profileName;
  List<ModelChoice> get choices => _choices;
  ModelChoice? get selected => _selected;
  bool get loading => _loading;
  bool get saving => _saving;
  bool get reviewing => _reviewing;
  bool get canReview =>
      !_disposed &&
      !_loading &&
      !_saving &&
      !_reviewing &&
      _needsReview &&
      _selected != null;
  String? get error => _error;
  String? get notice => _notice;
  bool get dirty => _selected != null && !_same(_saved, _selected);

  static bool _same(ModelChoice? a, ModelChoice? b) =>
      a?.provider == b?.provider && a?.model == b?.model;

  static ModelChoice? _current(Map<String, dynamic> value) =>
      ConfiguredModel.fromInfo(value).choice;

  bool _owns(int generation) => !_disposed && generation == _generation;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || _saving) return;
    final preservePending = dirty;
    final generation = ++_generation;
    ++_catalogGeneration;
    _retireReview();
    _loading = true;
    _error = null;
    _notice = null;
    _changed();
    try {
      final values = await Future.wait<Object>([
        _gateway.read('model/info'),
        _gateway.modelCatalog.load(explicitOnly: true, supersede: true),
      ]);
      final observation = ConfiguredModel.fromInfo(
        values[0] as Map<String, dynamic>,
      );
      final current = observation.choice;
      final choices = (values[1] as ModelCatalog).choices;
      if (!_owns(generation)) return;
      _choices = List.unmodifiable(choices);
      if (!preservePending || _openingModel == null) {
        _openingModel = observation;
        _saved =
            choices.where((choice) => _same(choice, current)).firstOrNull ??
            current;
        _selected = _saved;
        _needsReview = false;
      } else if (!_sameObservation(observation, _openingModel)) {
        _needsReview = true;
        _error = _conflictMessage;
      }
    } catch (_) {
      if (_owns(generation)) {
        _error = 'The profile models could not be loaded. Retry.';
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _changed();
      }
    }
  }

  void select(ModelChoice choice) {
    if (_disposed || _loading || _saving) return;
    if (!_choices.any((available) => _same(available, choice))) {
      throw ArgumentError('Model is outside the loaded catalog');
    }
    _retireReview();
    ++_revision;
    _needsReview = false;
    _selected = choice;
    _error = null;
    _notice = null;
    _changed();
  }

  static const _conflictMessage =
      'The profile model changed elsewhere. Review changes before saving.';

  static bool _sameObservation(ConfiguredModel a, ConfiguredModel? b) =>
      a.provider == b?.provider && a.model == b?.model;

  void _retireReview() {
    ++_reviewGeneration;
    _activeReview = null;
    _reviewing = false;
  }

  bool _ownsReview(int generation, int revision, int reviewGeneration) =>
      _owns(generation) &&
      revision == _revision &&
      reviewGeneration == _reviewGeneration &&
      !_loading &&
      !_saving;

  Future<ProfileModelChangeReview?> reviewPending() async {
    if (!canReview) return null;
    final wanted = _selected!;
    final generation = _generation;
    final revision = _revision;
    final reviewGeneration = ++_reviewGeneration;
    _activeReview = null;
    _reviewing = true;
    _error = null;
    _changed();
    bool owns() => _ownsReview(generation, revision, reviewGeneration);
    try {
      if (!owns()) return null;
      final current = ConfiguredModel.fromInfo(
        await _gateway.read('model/info'),
      );
      if (!owns()) return null;
      await _gateway.requireProfile();
      if (!owns()) return null;
      return _activeReview = ProfileModelChangeReview._(
        current,
        wanted,
        generation,
        revision,
        reviewGeneration,
      );
    } catch (_) {
      if (owns()) {
        _error =
            'The current profile model could not be reviewed. Your selection is kept. Retry review.';
      }
      return null;
    } finally {
      if (owns()) {
        _reviewing = false;
        _changed();
      }
    }
  }

  bool _ownsTicket(ProfileModelChangeReview ticket) =>
      identical(ticket, _activeReview) &&
      _ownsReview(
        ticket._generation,
        ticket._revision,
        ticket._reviewGeneration,
      ) &&
      _same(ticket.wanted, _selected);

  ProfileModelReviewOutcome cancelReview(ProfileModelChangeReview ticket) {
    if (!_ownsTicket(ticket)) return ProfileModelReviewOutcome.retired;
    _retireReview();
    return ProfileModelReviewOutcome.cancelled;
  }

  ProfileModelReviewOutcome applyReviewed(
    ProfileModelChangeReview ticket,
    ProfileModelReviewDecision decision,
  ) {
    if (!_ownsTicket(ticket)) return ProfileModelReviewOutcome.retired;
    _openingModel = ticket.current;
    final current = ticket.current.choice;
    _saved =
        _choices.where((choice) => _same(choice, current)).firstOrNull ??
        current;
    _selected = decision == ProfileModelReviewDecision.keepMine
        ? ticket.wanted
        : _saved;
    ++_revision;
    _retireReview();
    _needsReview = false;
    _error = null;
    _notice = null;
    _changed();
    return ProfileModelReviewOutcome.applied;
  }

  Future<List<ModelChoice>> refreshChoices() async {
    if (_disposed) throw StateError('Model edit is closed');
    if (_loading) throw StateError('Model edit is still loading');
    final generation = _generation;
    final catalogGeneration = ++_catalogGeneration;
    final choices = (await _gateway.modelCatalog.load(
      explicitOnly: true,
      refresh: true,
    )).choices;
    if (!_owns(generation) || catalogGeneration != _catalogGeneration) {
      throw StateError('Model edit is closed or superseded');
    }
    _choices = List.unmodifiable(choices);
    _changed();
    return _choices;
  }

  Future<Map<String, dynamic>> _write(
    ModelChoice wanted,
    int generation, {
    bool confirmed = false,
    required bool Function() canDispatch,
    required void Function() onDispatched,
  }) async {
    final current = ConfiguredModel.fromInfo(await _gateway.read('model/info'));
    if (!_owns(generation) || !canDispatch()) {
      throw StateError('Model edit retired before dispatch');
    }
    if (current.provider != _openingModel?.provider ||
        current.model != _openingModel?.model) {
      throw const _ModelEditConflict();
    }
    await _gateway.requireProfile();
    if (!_owns(generation) || !canDispatch()) {
      throw StateError('Model edit retired before dispatch');
    }
    return _gateway.postOwned(
      'model/set',
      {
        'scope': 'main',
        'provider': wanted.provider,
        'model': wanted.model,
        if (confirmed) 'confirm_expensive_model': true,
      },
      canDispatch: canDispatch,
      onDispatched: onDispatched,
    );
  }

  Future<ProfileModelSaveOutcome> save({
    required ConfirmProfileModel confirm,
  }) async {
    final wanted = _selected;
    if (_disposed ||
        _loading ||
        _saving ||
        _reviewing ||
        !dirty ||
        wanted == null) {
      return ProfileModelSaveOutcome.retired;
    }
    _retireReview();
    final generation = ++_generation;
    var dispatchActive = true;
    var dispatched = false;
    bool canDispatch() => dispatchActive && _owns(generation);
    void onDispatched() => dispatched = true;
    _saving = true;
    _error = null;
    _notice = null;
    _changed();
    try {
      var result = await _write(
        wanted,
        generation,
        canDispatch: canDispatch,
        onDispatched: onDispatched,
      );
      if (!_owns(generation)) return ProfileModelSaveOutcome.retired;
      if (result['confirm_required'] == true) {
        final raw = result['confirm_message'];
        final message = raw is String ? raw.trim() : '';
        final accepted = await confirm(
          message.isEmpty
              ? 'Hermes requires confirmation before using this model.'
              : message,
        );
        if (!_owns(generation)) return ProfileModelSaveOutcome.retired;
        if (!accepted) {
          _notice = 'Model change cancelled.';
          return ProfileModelSaveOutcome.cancelled;
        }
        result = await _write(
          wanted,
          generation,
          confirmed: true,
          canDispatch: canDispatch,
          onDispatched: onDispatched,
        );
      }
      if (!_owns(generation)) return ProfileModelSaveOutcome.retired;
      if (result['confirm_required'] == true || result['ok'] != true) {
        throw StateError('Model was not changed');
      }
      final authoritative = _current(await _gateway.read('model/info'));
      if (!_owns(generation)) return ProfileModelSaveOutcome.retired;
      if (authoritative == null || !_same(authoritative, wanted)) {
        throw StateError('Model readback did not match');
      }
      _saved = authoritative;
      _openingModel = ConfiguredModel(
        provider: authoritative.provider,
        model: authoritative.model,
      );
      _needsReview = false;
      return ProfileModelSaveOutcome.saved;
    } catch (failure) {
      if (!_owns(generation)) return ProfileModelSaveOutcome.retired;
      if (failure is _ModelEditConflict) _needsReview = true;
      _error = failure is _ModelEditConflict
          ? _conflictMessage
          : dispatched
          ? 'The model change could not be confirmed. Review the selection and try again.'
          : 'The model change was not sent. Your selection is kept. Try again.';
      return ProfileModelSaveOutcome.failed;
    } finally {
      dispatchActive = false;
      if (_owns(generation)) {
        _saving = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _catalogGeneration++;
    _retireReview();
    super.dispose();
  }
}

class _ModelEditConflict implements Exception {
  const _ModelEditConflict();
}
