import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/hermes_question.dart';

/// One device-owned history per authenticated conversation. First observation
/// fixes position; later outcomes cannot move the entry or grant live authority.
final class HermesQuestionHistory {
  factory HermesQuestionHistory(SharedPreferences preferences, String owner) =>
      (_owners[preferences] ??= {}).putIfAbsent(
        owner,
        () => HermesQuestionHistory._(preferences, owner),
      );

  HermesQuestionHistory._(this._preferences, String owner)
    : _key = 'hermes_question_history/$owner' {
    final saved = _preferences.getString(_key);
    if (saved == null) return;
    for (final value in jsonDecode(saved) as List) {
      final row = value as Map;
      final question = HermesQuestion.fromJson(row['question'] as Map);
      _entries[question.id] = PositionedHermesQuestion(
        question,
        afterMessage: row['after_message'],
        groupSequence: row['group_sequence'] as int?,
        afterTool: row['after_tool'] as String?,
      );
    }
  }

  static final _owners = Expando<Map<String, HermesQuestionHistory>>();
  final SharedPreferences _preferences;
  final String _key;
  final _entries = <String, PositionedHermesQuestion>{};
  Future<void> _writes = Future.value();
  String? error;

  Iterable<HermesQuestion> get questions =>
      _entries.values.map((entry) => entry.question);
  Iterable<PositionedHermesQuestion> get activities =>
      List.unmodifiable(_entries.values);
  HermesQuestion? question(String id) => _entries[id]?.question;

  void observe(
    HermesQuestion question, {
    Object? afterMessage,
    int? groupSequence,
    String? afterTool,
  }) {
    final old = _entries[question.id];
    if (old != null) {
      // A passive/stale read never erases an acknowledged answer or invents a
      // second occurrence of the same server-owned request.
      if (question.status.certainty < old.question.status.certainty) return;
      if (question.status == old.question.status &&
          (question.status != HermesQuestionStatus.pending ||
              (question.command == old.question.command &&
                  question.description == old.question.description &&
                  question.sender == old.question.sender))) {
        return;
      }
      _entries[question.id] = PositionedHermesQuestion(
        HermesQuestion(
          id: old.question.id,
          requestId: question.requestId,
          kind: old.question.kind,
          status: question.status,
          timestamp: old.question.timestamp,
          description: question.description,
          command: question.command,
          sender: question.sender,
        ),
        afterMessage: old.afterMessage,
        groupSequence: old.groupSequence,
        afterTool: old.afterTool,
      );
    } else {
      _entries[question.id] = PositionedHermesQuestion(
        question,
        afterMessage: afterMessage,
        groupSequence: groupSequence,
        afterTool: afterTool,
      );
    }
    _save();
  }

  void settle(String id, HermesQuestionStatus status) {
    final old = question(id);
    if (old != null) observe(old.withStatus(status));
  }

  void reconcile(Set<String> active, {HermesQuestionKind? kind}) {
    for (final entry in questions.toList()) {
      if ((kind == null || entry.kind == kind) &&
          entry.status == HermesQuestionStatus.pending &&
          !active.contains(entry.id)) {
        settle(entry.id, HermesQuestionStatus.closed);
      }
    }
  }

  void _save() {
    final rows = [
      for (final entry in _entries.values)
        {
          'question': entry.question.toJson(),
          'after_message': entry.afterMessage,
          'group_sequence': entry.groupSequence,
          'after_tool': entry.afterTool,
        },
    ];
    _writes = _writes
        .then((_) async {
          if (!await _preferences.setString(_key, jsonEncode(rows))) {
            throw StateError('Hermes question history could not be saved.');
          }
          error = null;
        })
        .catchError((Object _) {
          error = 'Hermes question history could not be saved on this device.';
        });
  }

  Future<void> flush() async {
    await _writes;
    if (error case final message?) throw StateError(message);
  }
}
