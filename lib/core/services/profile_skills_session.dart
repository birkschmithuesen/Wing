import 'package:flutter/foundation.dart';
import '../models/profile_skills.dart';
import '../models/skill_reader.dart';
import 'skill_reader_session.dart';
import 'administration_repository.dart';
import 'administration_operation_session.dart';
import 'connection_manager.dart' show DashboardHttpException;
import 'workspace_connection_failure.dart';

/// Captured library or Hub route. Children borrow observations and issued authority.
class ProfileSkillsSession extends ChangeNotifier {
  SkillReaderSession reader(SkillReaderTarget document) =>
      _profile.server.skillReader(document, profileName);
  ProfileSkillsSession.library(this._profile) : _hub = false {
    _profile.server.retain();
  }
  ProfileSkillsSession.hub(this._profile) : _hub = true {
    _profile.server.retain();
  }
  final ProfileAdministration _profile;
  final bool _hub;
  String get profileName => _profile.name;
  String get scopeLabel => _profile.label;
  List<InstalledSkill> _installed = const [];
  List<HubSkill> _catalog = const [];
  SkillInstructions? _instructions;
  SkillPreview? _preview;
  SkillEditObservation? _edit;
  SkillDetailRoute? _detail;
  SkillPreviewRoute? _previewRoute;
  SkillEditorRoute? _editor;
  SkillsPhase _phase = SkillsPhase.idle;
  bool _verified = false, _partial = false, _review = false, _retryable = false;
  String? _error, _notice;
  String _query = '';
  bool _libraryChecked = false, _catalogChecked = false;
  int _generation = 0, _notificationDepth = 0;
  bool _disposed = false, _pendingRefresh = false;
  ProfileSkillsState get state => ProfileSkillsState(
    installed: _installed,
    catalog: _catalog,
    instructions: _instructions,
    preview: _preview,
    edit: _edit,
    phase: _phase,
    verified: _verified,
    hasObservation: _detail != null
        ? _instructions != null
        : _previewRoute != null
        ? _preview != null
        : _hub
        ? _catalogChecked
        : _libraryChecked,
    partial: _partial,
    reviewRequired: _review,
    error: _error,
    notice: _notice,
  );
  bool get canRecoverRead =>
      !_disposed && _phase == SkillsPhase.idle && _retryable;
  bool _owns(int generation) => !_disposed && generation == _generation;
  void _emit() {
    if (_disposed) return;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Future<List<InstalledSkill>> _readInstalled() async =>
      InstalledSkill.decode(await _profile.read('skills'));
  Future<SkillInstructions> _readInstructions(String name) async =>
      SkillInstructions.decode(
        await _profile.read('skills/content', {'name': name}),
        name,
      );

  Future<(List<HubSkill>, bool)> _readHub(String query) async {
    final result = await _profile.read(
      query.isEmpty ? 'skills/hub/official' : 'skills/hub/search',
      query.isEmpty ? const {} : {'q': query, 'limit': '30'},
    );
    final rows = HubSkill.decode(result, searching: query.isNotEmpty);
    final timedOut = result['timed_out'];
    if (query.isNotEmpty &&
        (timedOut is! List || timedOut.any((v) => v is! String))) {
      throw const FormatException('Invalid partial catalog observation');
    }
    return (rows, timedOut is List && timedOut.isNotEmpty);
  }

  Future<void> refresh({String? query}) async {
    if (_disposed) return;
    if (query != null) _query = query.trim();
    if (_phase != SkillsPhase.idle && _phase != SkillsPhase.reading) {
      _pendingRefresh = true;
      return;
    }
    final generation = ++_generation;
    final search = _query;
    _phase = SkillsPhase.reading;
    _verified = false;
    _error = null;
    _retryable = false;
    _profile.server.retain();
    _emit();
    try {
      if (!_owns(generation)) return;
      if (_hub) {
        final result = await _readHub(search);
        if (!_owns(generation)) return;
        _catalog = result.$1;
        _partial = result.$2;
        _catalogChecked = true;
      } else {
        final rows = await _readInstalled();
        if (!_owns(generation)) return;
        _installed = rows;
        _libraryChecked = true;
      }
      _verified = true;
      _review = false;
    } catch (error) {
      if (_owns(generation)) {
        _error = administrationError(error);
        _retryable = isTemporaryWorkspaceFailure(error);
      }
    } finally {
      _profile.server.release();
      if (_owns(generation)) {
        _phase = SkillsPhase.idle;
        _emit();
      }
    }
  }

  SkillDetailRoute openSkill(InstalledSkill skill) {
    if (_disposed ||
        !state.canMutate ||
        !_installed.any((s) => identical(s, skill))) {
      throw const AdministrationFailure(
        'Refresh the skill library before opening this skill.',
      );
    }
    _instructions = null;
    _edit = null;
    return _detail = SkillDetailRoute(skill);
  }

  SkillPreviewRoute openPreview(HubSkill skill) {
    if (_disposed ||
        !state.canMutate ||
        !_catalog.any((s) => identical(s, skill))) {
      throw const AdministrationFailure(
        'Refresh the catalog before opening this skill.',
      );
    }
    _preview = null;
    return _previewRoute = SkillPreviewRoute(skill);
  }

  void releaseDetail(SkillDetailRoute route) {
    if (!identical(_detail, route)) return;
    _detail = null;
    _editor = null;
    if (_phase == SkillsPhase.reading) {
      ++_generation;
      _phase = SkillsPhase.idle;
      _verified = false;
      _emit();
    }
  }

  void releasePreview(SkillPreviewRoute route) {
    if (!identical(_previewRoute, route)) return;
    _previewRoute = null;
    if (_phase == SkillsPhase.reading) {
      ++_generation;
      _phase = SkillsPhase.idle;
      _verified = false;
      _emit();
    }
  }

  Future<void> loadDetail(SkillDetailRoute route) => _readChild(
    () => identical(_detail, route),
    () async {
      final rows = await _readInstalled();
      final matches = rows.where((s) => s.name == route.skill.name);
      if (matches.length != 1) {
        throw const AdministrationFailure('This skill is no longer installed.');
      }
      final content = await _readInstructions(route.skill.name);
      return () {
        _installed = rows;
        _libraryChecked = true;
        _instructions = content;
      };
    },
  );
  Future<void> loadPreview(SkillPreviewRoute route) =>
      _readChild(() => identical(_previewRoute, route), () async {
        final preview = SkillPreview.decode(
          await _profile.read('skills/hub/preview', {
            'identifier': route.skill.identifier,
          }),
          route.skill.identifier,
        );
        return () {
          _preview = preview;
        };
      });
  Future<void> _readChild(
    bool Function() child,
    Future<void Function()> Function() read,
  ) async {
    if (_disposed ||
        !child() ||
        _phase != SkillsPhase.idle && _phase != SkillsPhase.reading) {
      return;
    }
    final generation = ++_generation;
    _phase = SkillsPhase.reading;
    _verified = false;
    _error = null;
    _retryable = false;
    _profile.server.retain();
    _emit();
    try {
      if (!_owns(generation) || !child()) return;
      final apply = await read();
      if (!_owns(generation) || !child()) return;
      apply();
      _verified = true;
      _review = false;
    } catch (error) {
      if (_owns(generation) && child()) {
        _error = administrationError(error);
        _retryable = isTemporaryWorkspaceFailure(error);
      }
    } finally {
      _profile.server.release();
      if (_owns(generation) && child()) {
        _phase = SkillsPhase.idle;
        _emit();
      }
    }
  }

  InstalledSkill? currentSkill(SkillDetailRoute route) =>
      _installed.where((s) => s.name == route.skill.name).firstOrNull;
  bool canEdit(SkillDetailRoute route) =>
      identical(_detail, route) &&
      state.canMutate &&
      currentSkill(route)?.editable == true &&
      _instructions?.name == route.skill.name;
  bool canUninstall(SkillDetailRoute route) =>
      identical(_detail, route) &&
      state.canMutate &&
      currentSkill(route)?.uninstallable == true;
  bool canSetLocked(SkillDetailRoute route) =>
      identical(_detail, route) &&
      state.canMutate &&
      currentSkill(route) != null;

  Future<bool> setLocked(SkillDetailRoute route, bool locked) async {
    final before = currentSkill(route);
    if (!canSetLocked(route) || before == null || before.locked == locked) {
      return false;
    }
    return _mutation(
      confirm: () async => true,
      child: () => identical(_detail, route),
      preflight: () async {
        final current = (await _readInstalled())
            .where((s) => s.name == before.name)
            .firstOrNull;
        if (current == null ||
            current.provenance != before.provenance ||
            current.locked != before.locked) {
          throw const AdministrationFailure(
            'This skill changed. Refresh and review its lock.',
          );
        }
      },
      method: 'PUT',
      path: 'skills/lock',
      body: {'name': before.name, 'locked': locked},
      ack: (result) =>
          result['ok'] == true &&
          result['name'] == before.name &&
          result['locked'] == locked,
      notice: locked
          ? 'Skill locked against agent edits.'
          : 'Skill unlocked for agent edits.',
      after: () async {
        final rows = await _readInstalled();
        final confirmed = rows.where((s) => s.name == before.name).firstOrNull;
        if (confirmed == null || confirmed.locked != locked) {
          throw const AdministrationFailure(
            'The skill lock could not be verified. Refresh to check it.',
          );
        }
        return () {
          _installed = rows;
          _libraryChecked = true;
          _notice = null;
        };
      },
    );
  }

  SkillEditorRoute openEditor(SkillDetailRoute route) {
    if (!canEdit(route)) {
      throw const AdministrationFailure(
        'These instructions are not available for editing.',
      );
    }
    final content = _instructions!;
    _edit = SkillEditObservation(content.content, content.content, false);
    return _editor = SkillEditorRoute(content.name, content.content);
  }

  void releaseEditor(SkillEditorRoute editor) {
    if (identical(_editor, editor)) _editor = null;
  }

  void edit(SkillEditorRoute editor, String text) {
    if (_disposed || !identical(_editor, editor)) return;
    _edit = SkillEditObservation(_edit!.saved, text, false);
    if (_verified && !_review) _error = null;
    _emit();
  }

  Future<bool> requestClose(
    SkillEditorRoute editor,
    Future<bool> Function() confirm,
  ) async {
    if (_disposed || !identical(_editor, editor) || state.busy) return false;
    final draft = _edit!.draft;
    if (_edit!.dirty && !await confirm()) return false;
    if (_disposed ||
        !identical(_editor, editor) ||
        state.busy ||
        _edit!.draft != draft) {
      return false;
    }
    _edit = SkillEditObservation(_edit!.saved, _edit!.draft, true);
    _emit();
    return !_disposed && identical(_editor, editor);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic> body,
    bool Function() active,
    void Function() dispatched,
  ) async {
    await _profile.requireProfile();
    if (!active()) {
      throw const AdministrationFailure('This skill editor is closed.');
    }
    return _profile.server.ownedMutation(
      method,
      path,
      {'profile': profileName},
      {...body, 'profile': profileName},
      active,
      dispatched,
    );
  }

  Future<void> save(SkillEditorRoute editor) async {
    if (_disposed || !identical(_editor, editor) || !state.canSave) return;
    final desired = _edit!.draft, baseline = _edit!.saved;
    final generation = ++_generation;
    bool live() => _owns(generation);
    bool active() => live() && identical(_editor, editor);
    var dispatched = false, acknowledged = false, preflightVerified = false;
    _phase = SkillsPhase.saving;
    _error = null;
    _notice = null;
    _profile.server.retain();
    _emit();
    try {
      if (!active()) return;
      final rows = await _readInstalled();
      if (!active()) return;
      if (!rows.any((s) => s.name == editor.name && s.editable)) {
        throw const AdministrationFailure(
          'This skill’s origin changed. Your draft is kept.',
        );
      }
      final current = await _readInstructions(editor.name);
      if (!active()) return;
      if (current.content == desired) {
        _edit = SkillEditObservation(desired, _edit!.draft, false);
        _instructions = current;
        return;
      }
      if (current.content != baseline) {
        throw const AdministrationFailure(
          'Instructions changed on the server. Keep your draft and reopen the skill to review the changes.',
        );
      }
      preflightVerified = true;
      final result = await _send(
        'PUT',
        'skills/content',
        {'name': editor.name, 'content': desired},
        active,
        () => dispatched = true,
      );
      if (result['success'] != true) {
        throw const FormatException('Instruction save was not acknowledged');
      }
      acknowledged = true;
      if (!live()) return;
      _edit = SkillEditObservation(desired, _edit!.draft, false);
      _notice = 'Instructions saved. Hermes can reload them in this chat.';
      _verified = false;
      _emit();
      if (!live()) return;
      final after = await _readInstructions(editor.name);
      if (!live()) return;
      _instructions = after;
      _verified = true;
      if (after.content != desired) {
        _error =
            'Instructions were saved, but changed again on the server. Reopen the skill to review.';
      }
    } catch (error) {
      if (live()) {
        _verified = preflightVerified && !acknowledged && _rejected(error);
        _review = dispatched && !acknowledged && !_rejected(error);
        _error = acknowledged
            ? 'Instructions saved. The current instructions are unavailable; refresh to check them.'
            : _review
            ? 'Instruction save was not confirmed. Your draft is kept. Refresh to check the server before trying again.'
            : administrationError(error, writing: true);
      }
    } finally {
      _profile.server.release();
      if (live()) {
        _phase = SkillsPhase.idle;
        _emit();
        if (_pendingRefresh && live()) {
          _pendingRefresh = false;
          await refresh();
        }
      }
    }
  }

  Future<bool> archive(
    SkillDetailRoute route,
    Future<bool> Function() confirm,
  ) async {
    if (!canEdit(route)) return false;
    return _mutation(
      confirm: confirm,
      child: () => identical(_detail, route),
      preflight: () async {
        final rows = await _readInstalled();
        if (!rows.any((s) => s.name == route.skill.name && s.editable)) {
          throw const AdministrationFailure(
            'This skill’s origin changed. Refresh and review.',
          );
        }
      },
      method: 'DELETE',
      path: 'learning/node',
      body: {'id': route.skill.name},
      ack: (result) => result['ok'] == true,
      notice: 'Skill archived.',
      after: () async {
        final rows = await _readInstalled();
        if (rows.any((s) => s.name == route.skill.name)) {
          throw const AdministrationFailure(
            'Archive acknowledged, but this name is still in the library. Refresh to review.',
          );
        }
        return () {
          _installed = rows;
          _libraryChecked = true;
        };
      },
    );
  }

  Future<void> uninstall(
    SkillDetailRoute route, {
    required Future<bool> Function() confirm,
    required Future<void> Function(AdministrationOperationSession) showResult,
  }) async {
    if (!canUninstall(route)) return;
    await _operation(
      'uninstall',
      route.skill.name,
      confirm,
      showResult,
      () => identical(_detail, route),
      () async {
        if (!(await _readInstalled()).any(
          (s) => s.name == route.skill.name && s.uninstallable,
        )) {
          throw const AdministrationFailure(
            'This is no longer an installed Hub skill.',
          );
        }
      },
    );
  }

  Future<void> update({
    required Future<bool> Function() confirm,
    required Future<void> Function(AdministrationOperationSession) showResult,
  }) async {
    if (!_hub || !state.canMutate) return;
    await _operation(
      'update',
      '',
      confirm,
      showResult,
      () => true,
      () async {},
    );
  }

  Future<void> install(
    SkillPreviewRoute route, {
    required Future<bool> Function() confirm,
    required Future<void> Function(AdministrationOperationSession) showResult,
  }) async {
    if (!identical(_previewRoute, route) ||
        !state.canMutate ||
        _preview == null) {
      return;
    }
    await _operation(
      'install',
      route.skill.identifier,
      confirm,
      showResult,
      () => identical(_previewRoute, route),
      () async {
        SkillPreview.decode(
          await _profile.read('skills/hub/preview', {
            'identifier': route.skill.identifier,
          }),
          route.skill.identifier,
        );
      },
    );
  }

  Future<void> _operation(
    String verb,
    String key,
    Future<bool> Function() confirm,
    Future<void> Function(AdministrationOperationSession) showResult,
    bool Function() child,
    Future<void> Function() preflight,
  ) async {
    final expected = verb == 'update'
        ? 'skills-update'
        : skillHubActionName(verb, key);
    await _mutation(
      confirm: confirm,
      child: child,
      preflight: preflight,
      method: 'POST',
      path: 'skills/hub/$verb',
      body: {
        if (verb == 'install') 'identifier': key,
        if (verb == 'uninstall') 'name': key,
      },
      ack: (r) =>
          r['ok'] == true &&
          r['name'] == expected &&
          r['pid'] is int &&
          (r['pid'] as int) > 0,
      notice:
          '${verb == 'update'
              ? 'Update'
              : verb == 'install'
              ? 'Install'
              : 'Uninstall'} started.',
      result: showResult,
      after: () async {
        final rows = await _readInstalled();
        final hub = verb == 'update' ? await _readHub(_query) : null;
        return () {
          _installed = rows;
          _libraryChecked = true;
          if (hub != null) {
            _catalog = hub.$1;
            _partial = hub.$2;
            _catalogChecked = true;
          }
          if (verb == 'install') {
            _notice =
                'Inventory refreshed: ${rows.length} installed skills. Check the operation result above.';
          }
        };
      },
    );
  }

  Future<bool> _mutation({
    required Future<bool> Function() confirm,
    required bool Function() child,
    required Future<void> Function() preflight,
    required String method,
    required String path,
    required Map<String, dynamic> body,
    required bool Function(Map<String, dynamic>) ack,
    required String notice,
    required Future<void Function()> Function() after,
    Future<void> Function(AdministrationOperationSession)? result,
  }) async {
    if (_disposed || !state.canMutate) return false;
    final generation = ++_generation;
    bool live() => _owns(generation);
    bool active() => live() && child();
    var dispatched = false, acknowledged = false;
    _phase = SkillsPhase.confirming;
    _error = null;
    _notice = null;
    _profile.server.retain();
    _emit();
    try {
      if (!active() || !await confirm() || !active()) return false;
      _phase = SkillsPhase.saving;
      _emit();
      if (!active()) return false;
      await preflight();
      if (!active()) return false;
      final receipt = await _send(
        method,
        path,
        body,
        active,
        () => dispatched = true,
      );
      if (!ack(receipt)) {
        throw const FormatException('Skill command was not acknowledged');
      }
      acknowledged = true;
      if (!live()) return false;
      _notice = notice;
      _verified = false;
      _emit();
      if (!live()) return false;
      if (result != null) {
        final operation = AdministrationOperationSession.fromReceipt(
          _profile.server,
          receipt,
        );
        try {
          _phase = SkillsPhase.result;
          _emit();
          if (active()) await result(operation);
        } finally {
          operation.dispose();
        }
      }
      if (!live()) return false;
      final apply = await after();
      if (!live()) return false;
      apply();
      _verified = true;
      return active();
    } catch (error) {
      if (live()) {
        _verified = false;
        _review = dispatched && !acknowledged && !_rejected(error);
        _error = acknowledged
            ? '$notice Its result or current library is unavailable; refresh to check it.'
            : _review
            ? 'The skill command was not confirmed. Refresh to check the server before trying again.'
            : administrationError(error, writing: true);
      }
      return false;
    } finally {
      _profile.server.release();
      if (live()) {
        _phase = SkillsPhase.idle;
        _emit();
        if (_pendingRefresh && live()) {
          _pendingRefresh = false;
          await refresh();
        }
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _profile.server.release();
    if (_notificationDepth == 0) super.dispose();
  }
}

bool _rejected(Object error) =>
    error is DashboardHttpException &&
    const {400, 401, 403, 404, 405, 422}.contains(error.statusCode);
