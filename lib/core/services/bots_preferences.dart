import '../models/bots.dart';
import 'conversation_reading_memory.dart';
import '../models/hermes_question.dart';
import 'hermes_question_history.dart';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../models/composer_reference.dart';

class _MessageDraftWrites {
  final tails = <String, Future<void>>{};
  final pending = <String, String?>{};
  final revisions = <String, int>{};
}

/// Device-owned room pins, prompts and message drafts, scoped by instance/room.
class BotsPreferences {
  BotsPreferences(this._preferences);
  final SharedPreferences _preferences;
  ConversationReadingRegistry get readingPositions =>
      ConversationReadingRegistry(_preferences);
  static final _draftWrites = Expando<_MessageDraftWrites>();
  _MessageDraftWrites get _writes =>
      _draftWrites[_preferences] ??= _MessageDraftWrites();
  static const _pinsKey = 'bots_group_pins_v1';
  static Future<BotsPreferences> load() async =>
      BotsPreferences(await SharedPreferences.getInstance());
  Set<String> get pins =>
      Set.unmodifiable(_preferences.getStringList(_pinsKey) ?? <String>[]);
  Future<void> writePins(Set<String> pins) async {
    if (!await _preferences.setStringList(_pinsKey, pins.toList()..sort())) {
      throw StateError('Group pin could not be saved');
    }
  }

  String _picturePromptKey(String identity, String roomId) =>
      'bots_group_picture_prompt:${jsonEncode([identity, roomId])}';

  String? picturePrompt(String identity, String roomId) =>
      _preferences.getString(_picturePromptKey(identity, roomId));

  Future<void> writePicturePrompt(
    String identity,
    String roomId,
    String prompt,
  ) async {
    if (!await _preferences.setString(
      _picturePromptKey(identity, roomId),
      prompt,
    )) {
      throw StateError('Room picture prompt could not be saved');
    }
  }

  HermesQuestionHistory questions(String identity, String roomId) =>
      HermesQuestionHistory(
        _preferences,
        jsonEncode(['group', identity, roomId]),
      );

  void observeQuestions(BotGroup group, BotGroupRuntime runtime, int sequence) {
    final history = questions(group.scope.connectionIdentity, group.id);
    final actions = runtime.actions.where(
      (action) => action.kind == 'approval',
    );
    for (final action in actions) {
      history.observe(
        HermesQuestion(
          id: action.key,
          requestId: action.request,
          kind: HermesQuestionKind.approval,
          status: HermesQuestionStatus.pending,
          timestamp: DateTime.now(),
          description: action.description,
          command: action.command,
          sender:
              group.members
                  .where((member) => member.id == action.member)
                  .firstOrNull
                  ?.name ??
              action.member,
        ),
        groupSequence: sequence,
      );
    }
    history.reconcile(actions.map((action) => action.key).toSet());
  }

  /// Live room state is required; a settled receipt can only remove authority.
  List<BotGroupAction> pendingApprovals(
    BotGroup group,
    BotGroupRuntime runtime,
  ) {
    final current = {
      for (final action in runtime.actions)
        if (action.kind == 'approval') action.key: action,
    };
    return List.unmodifiable([
      for (final question in questions(
        group.scope.connectionIdentity,
        group.id,
      ).questions)
        if (question.status.isPending) ?current[question.id],
    ]);
  }

  String _messageDraftKey(String identity, String roomId) =>
      'bots_group_message_draft:${jsonEncode([identity, roomId])}';

  ({
    String text,
    List<ComposerReference> references,
    List<BotGroupAttachment> attachments,
    String? pendingEventId,
    String? pendingWireText,
    String? pendingText,
    BotGroupReply? reply,
  })?
  messageDraft(String identity, String roomId) {
    final key = _messageDraftKey(identity, roomId);
    final saved = _writes.pending.containsKey(key)
        ? _writes.pending[key]
        : _preferences.getString(key);
    if (saved == null) return null;
    final record = jsonDecode(saved);
    if (record is! Map || record['text'] is! String) {
      throw const FormatException('Invalid group message draft');
    }
    return (
      text: record['text'] as String,
      references: ComposerReference.decode(record['references']),
      attachments: [
        for (final value in (record['attachments'] as List? ?? const []))
          BotGroupAttachment.fromJson(Map<String, dynamic>.from(value as Map)),
      ],
      pendingEventId: record['pending_event_id'] as String?,
      pendingWireText: record['pending_wire_text'] as String?,
      pendingText: record['pending_text'] as String?,
      reply: record['reply'] == null
          ? null
          : BotGroupReply.fromJson(
              Map<String, dynamic>.from(record['reply'] as Map),
            ),
    );
  }

  Future<void> acknowledgeMessageDraft(
    String identity,
    String roomId,
    String eventId,
    String text,
    Iterable<String> attachmentIds,
  ) async {
    final current = messageDraft(identity, roomId);
    if (current == null || current.pendingEventId != eventId) return;
    final remainingText = current.text.trim() == text ? '' : current.text;
    await writeMessageDraft(
      identity,
      roomId,
      remainingText,
      retainComposerReferences(remainingText, current.references),
      attachments: current.attachments
          .where((item) => !attachmentIds.contains(item.id))
          .toList(),
    );
  }

  int messageDraftRevision(String identity, String roomId) =>
      _writes.revisions[_messageDraftKey(identity, roomId)] ?? 0;

  Future<void> writeMessageDraft(
    String identity,
    String roomId,
    String text,
    List<ComposerReference> references, {
    List<BotGroupAttachment> attachments = const [],
    String? pendingEventId,
    String? pendingWireText,
    String? pendingText,
    BotGroupReply? reply,
  }) {
    final key = _messageDraftKey(identity, roomId);
    final encoded =
        text.isEmpty &&
            attachments.isEmpty &&
            pendingEventId == null &&
            reply == null
        ? null
        : jsonEncode({
            'text': text,
            'references': references.map((ref) => ref.toJson()).toList(),
            'attachments': attachments.map((item) => item.toJson()).toList(),
            'pending_event_id': ?pendingEventId,
            'pending_wire_text': ?pendingWireText,
            'pending_text': ?pendingText,
            'reply': ?reply?.toJson(),
          });
    final writes = _writes;
    writes.pending[key] = encoded;
    final revision = writes.revisions[key] = (writes.revisions[key] ?? 0) + 1;
    final operation = (writes.tails[key] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          final saved = encoded == null
              ? await _preferences.remove(key)
              : await _preferences.setString(key, encoded);
          if (!saved) {
            throw StateError('Group message draft could not be saved');
          }
          if (writes.revisions[key] == revision) writes.pending.remove(key);
        });
    writes.tails[key] = operation;
    return operation.whenComplete(() {
      if (identical(writes.tails[key], operation)) writes.tails.remove(key);
    });
  }
}
