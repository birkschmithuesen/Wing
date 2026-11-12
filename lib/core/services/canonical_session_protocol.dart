import 'package:uuid/uuid.dart';

import '../models/canonical_session.dart';
import 'ws_client.dart';

/// One profile's canonical session authority observations. The owning gateway
/// retires these on disconnect; draft identity lives in Composer instead.
final class CanonicalSessionProtocol {
  final _sessions = <String, CanonicalSessionObservation>{};
  final _needsSnapshot = <String>{};
  final _expectedReplayEpoch = <String, String>{};
  final _retiredReplayEpochs = <String, Set<String>>{};

  CanonicalSessionObservation? session(String id) => _sessions[id];
  bool needsSnapshot(String id) => _needsSnapshot.contains(id);
  void clear() {
    _sessions.clear();
    _needsSnapshot.clear();
    _expectedReplayEpoch.clear();
    _retiredReplayEpochs.clear();
  }

  bool snapshot(Map<String, dynamic> value) {
    final id = value['session_id'];
    if (id is! String) throw const FormatException('Missing session identity');
    final revision = value['revision'],
        generation = value['execution_generation'];
    final epoch = value['authority_epoch'], replay = value['replay_epoch'];
    final sequence = value['last_sequence'],
        subscription = value['subscription_id'];
    if (revision is! int ||
        generation is! int ||
        epoch is! int ||
        replay is! String ||
        sequence is! int ||
        subscription is! String ||
        value['pending'] is! List) {
      throw const FormatException(
        'Hermes did not return a canonical session snapshot',
      );
    }
    final previous = _sessions[id];
    if (_retiredReplayEpochs[id]?.contains(replay) == true) return false;
    if (_expectedReplayEpoch[id] != null &&
            _expectedReplayEpoch[id] != replay ||
        previous != null && epoch < previous.authorityEpoch) {
      return false;
    }
    if (previous != null &&
        previous.replayEpoch == replay &&
        (sequence < previous.sequence ||
            revision < previous.revision ||
            generation < previous.generation)) {
      return false;
    }
    if (previous != null && previous.replayEpoch != replay) {
      _retiredReplayEpochs
          .putIfAbsent(id, () => <String>{})
          .add(previous.replayEpoch);
    }
    _sessions[id] = CanonicalSessionObservation(
      sessionId: id,
      revision: previous?.replayEpoch == replay
          ? _forward(previous!.revision, revision)
          : revision,
      generation: previous?.replayEpoch == replay
          ? _forward(previous!.generation, generation)
          : generation,
      authorityEpoch: epoch,
      replayEpoch: replay,
      sequence: sequence,
      subscriptionId: subscription,
      pending: _pending(id, value['pending']),
      readOnlyReason: _sessions[id]?.readOnlyReason,
    );
    _needsSnapshot.remove(id);
    _expectedReplayEpoch.remove(id);
    return true;
  }

  List<CanonicalAdmission> _pending(String id, Object? value) {
    if (value is! List) {
      throw const FormatException('Missing pending admissions');
    }
    final rows = value.map((row) {
      if (row is! Map) throw const FormatException('Invalid pending admission');
      final admission = CanonicalAdmission.fromJson(row);
      if (admission.sessionId != id) {
        throw const FormatException('Admission belongs to another session');
      }
      return admission;
    }).toList()..sort((a, b) => a.sequence.compareTo(b.sequence));
    return rows;
  }

  /// Returns false for duplicate or incomplete streams. A gap requires an
  /// authoritative snapshot; advancing a cursor cannot establish missing state.
  bool event(StreamEvent event) {
    final id = event.sessionId;
    final previous = _sessions[id];
    if (previous == null) return true;
    final epoch = event.envelope['replay_epoch'];
    final sequence = event.envelope['seq'];
    final authority = event.envelope['authority_epoch'];
    final generation = event.envelope['execution_generation'];
    if (epoch is String && _retiredReplayEpochs[id]?.contains(epoch) == true) {
      return false;
    }
    if (event.type == 'session.replay_gap' ||
        authority is int && authority != previous.authorityEpoch ||
        epoch is String && epoch != previous.replayEpoch ||
        sequence is int && sequence > previous.sequence + 1) {
      _needsSnapshot.add(id!);
      if (epoch is String && epoch != previous.replayEpoch) {
        _expectedReplayEpoch[id] = epoch;
      }
      return false;
    }
    if (_needsSnapshot.contains(id)) return false;
    if (sequence is int && sequence <= previous.sequence) return false;
    final data = event.data;
    _sessions[id!] = CanonicalSessionObservation(
      sessionId: id,
      revision: _forward(previous.revision, data['revision']),
      generation: _forward(
        _forward(previous.generation, generation),
        data['execution_generation'],
      ),
      authorityEpoch: previous.authorityEpoch,
      replayEpoch: previous.replayEpoch,
      sequence: sequence is int ? sequence : previous.sequence,
      subscriptionId: previous.subscriptionId,
      pending: data.containsKey('pending')
          ? _pending(id, data['pending'])
          : previous.pending,
      readOnlyReason: previous.readOnlyReason,
    );
    return true;
  }

  int _forward(int current, Object? value) =>
      value is int && value > current ? value : current;

  void admission(
    CanonicalAdmission receipt, {
    required String inputId,
    required String text,
    required int observedSequence,
  }) {
    final current = _sessions[receipt.sessionId];
    if (current == null) {
      throw StateError('The submission session is no longer attached.');
    }
    // A late ACK cannot undo a newer claim/settlement already observed live.
    if (current.sequence > observedSequence ||
        current.pending.any((row) => row.id == receipt.id)) {
      return;
    }
    final rows = current.pending.toList();
    if (receipt.status != 'terminal') {
      rows.add(
        CanonicalAdmission(
          id: receipt.id,
          inputId: inputId,
          sessionId: receipt.sessionId,
          sequence: receipt.sequence,
          status: receipt.status,
          text: text,
          generation: receipt.generation,
          controls: receipt.controls,
          outcome: receipt.outcome,
          steering: receipt.steering,
        ),
      );
    }
    rows.sort((a, b) => a.sequence.compareTo(b.sequence));
    _sessions[receipt.sessionId] = CanonicalSessionObservation(
      sessionId: current.sessionId,
      revision: current.revision,
      generation: current.generation,
      authorityEpoch: current.authorityEpoch,
      replayEpoch: current.replayEpoch,
      sequence: current.sequence,
      subscriptionId: current.subscriptionId,
      pending: rows,
      readOnlyReason: current.readOnlyReason,
    );
  }

  void mutationResult(String id, Map<String, dynamic> result) {
    final previous = _sessions[id];
    if (previous == null || result['status'] == 'confirmation_required') return;
    if (result['session_id'] != id) {
      throw const FormatException('Mutation belongs to another session');
    }
    _sessions[id] = CanonicalSessionObservation(
      sessionId: id,
      revision: _forward(previous.revision, result['revision']),
      generation: _forward(previous.generation, result['execution_generation']),
      authorityEpoch: previous.authorityEpoch,
      replayEpoch: previous.replayEpoch,
      sequence: previous.sequence,
      subscriptionId: previous.subscriptionId,
      pending: previous.pending,
      readOnlyReason: previous.readOnlyReason,
    );
  }

  void refused(String id, JsonRpcError error) {
    final previous = _sessions[id];
    if (previous == null) return;
    final readOnly = const {
      'session_read_only',
      'session_superseded',
    }.contains(error.reason);
    _sessions[id] = CanonicalSessionObservation(
      sessionId: id,
      revision: _forward(previous.revision, error.data['revision']),
      generation: _forward(
        previous.generation,
        error.data['execution_generation'],
      ),
      authorityEpoch: previous.authorityEpoch,
      replayEpoch: previous.replayEpoch,
      sequence: previous.sequence,
      subscriptionId: previous.subscriptionId,
      pending: previous.pending,
      readOnlyReason: readOnly ? error.reason : previous.readOnlyReason,
    );
  }

  Map<String, dynamic> mutation(
    String id,
    String operation,
    Map<String, dynamic> payload,
  ) {
    final current = _sessions[id];
    if (current == null || _needsSnapshot.contains(id)) {
      throw StateError(
        'Reconnect to refresh this conversation before changing it.',
      );
    }
    if (current.readOnlyReason != null) {
      throw StateError(
        'This conversation is read-only. Start a new chat to continue.',
      );
    }
    return {
      'session_id': id,
      'request_id': const Uuid().v4(),
      'expected_revision': current.revision,
      'expected_generation': current.generation,
      'operation': operation,
      'payload': payload,
    };
  }

  Map<String, dynamic> interrupt(String id) {
    final current = _sessions[id];
    if (current == null || _needsSnapshot.contains(id)) {
      throw StateError(
        'Reconnect to refresh the running turn before stopping it.',
      );
    }
    return {'session_id': id, 'execution_generation': current.generation};
  }

  Map<String, dynamic> replay(String id) {
    final current = _sessions[id];
    if (current == null) {
      throw StateError('Open the conversation before replaying it.');
    }
    return {
      'session_id': id,
      'replay_epoch': current.replayEpoch,
      'last_sequence': current.sequence,
    };
  }
}
