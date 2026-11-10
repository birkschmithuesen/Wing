import 'package:flutter/foundation.dart';
import '../models/profile_session_key.dart';
import 'administration_operation_session.dart';
import 'profile_workspace_controller.dart';

/// One result route owns preparation/retry; the durable draft is workspace-owned.
class DoctorFindingDraftSession extends ChangeNotifier {
  DoctorFindingDraftSession(this._operation, this._controller) {
    _controller.addListener(_changed);
    _operation.addListener(_changed);
  }
  final AdministrationOperationSession _operation;
  final ProfileWorkspaceController _controller;
  ProfileSessionKey? _preparedKey;
  String? _preparedPrompt;
  int? _opening;
  String? _notice;
  int? _failedFinding;
  int? get failedFinding => _failedFinding;
  bool _disposed = false;
  int _notificationDepth = 0;
  int? get openingFinding => _opening;
  String? get notice => _notice;
  bool get _active => !_disposed && !_operation.state.retired;
  bool get canAsk =>
      _active &&
      _opening == null &&
      _controller.current != null &&
      !_controller.switching;
  void _changed() {
    if (!_active) return;
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Future<void> openFinding(
    int index, {
    required Future<void> Function(ProfileSessionKey) navigate,
    required bool Function() isRouteCurrent,
  }) async {
    if (!canAsk || !isRouteCurrent()) return;
    final owner = _controller.current!.scope;
    final observation = _operation.state.observation;
    final diagnosis = observation.diagnosis;
    if (diagnosis == null || index < 0 || index >= diagnosis.findings.length) {
      return;
    }
    _opening = index;
    _notice = null;
    _failedFinding = null;
    _changed();
    try {
      if (!_active || !isRouteCurrent()) return;
      if (owner.connectionId != _operation.connectionId ||
          owner.connectionIdentity != _operation.connectionIdentity) {
        _failedFinding = index;
        _notice = 'Connection changed. Open Doctor on the selected connection.';
        return;
      }
      final prompt = diagnosis.findings[index].chatPrompt(
        observation.lines.join('\n'),
      );
      final key = _preparedKey?.workspace == owner && _preparedPrompt == prompt
          ? _preparedKey!
          : (await _controller.createDraftChat(
              owner: owner,
              text: prompt,
              canDispatch: () => _active && isRouteCurrent(),
            )).key;
      if (!_active) return;
      _preparedKey = key;
      _preparedPrompt = prompt;
      if (!isRouteCurrent()) return;
      if (_controller.switching || _controller.current?.scope != owner) {
        _notice = 'Draft saved in ${owner.profileName}. Open it from Chats.';
        return;
      }
      await navigate(key);
      if (!_active) return;
      _preparedKey = null;
      _preparedPrompt = null;
    } catch (_) {
      if (!_disposed) {
        _failedFinding = index;
        _notice = 'Could not open the chat. Check the connection and retry.';
      }
    } finally {
      _opening = null;
      _changed();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_changed);
    _operation.removeListener(_changed);
    if (_notificationDepth == 0) super.dispose();
  }
}
