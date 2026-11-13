import '../models/composer_reference.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/attachment_draft.dart';
import '../models/queued_prompt_draft.dart';

class _DraftWrites {
  final tails = <String, Future<void>>{};
  final revisions = <String, int>{};
}

class ComposerDraftSnapshot {
  final String text;
  final List<ComposerReference> references;
  final List<AttachmentDraft> attachments;
  final bool submissionUncertain;
  final List<QueuedPromptDraft> queuedPrompts;
  final bool queuePaused;

  const ComposerDraftSnapshot({
    required this.text,
    this.references = const [],
    required this.attachments,
    required this.submissionUncertain,
    this.queuedPrompts = const [],
    this.queuePaused = false,
  });
}

typedef ComposerDraftSummary = ({
  String sessionId,
  String text,
  int attachmentCount,
  int queuedCount,
  bool submissionUncertain,
});

/// Stores only work that has not been accepted by Hermes yet.
class ComposerDraftStore {
  static final _writesByPreferences = Expando<_DraftWrites>();
  final SharedPreferences _preferences;
  final String connectionIdentity;

  ComposerDraftStore(this._preferences, {required this.connectionIdentity}) {
    if (connectionIdentity.isEmpty) {
      throw ArgumentError('A verified connection identity is required');
    }
  }

  _DraftWrites get _writes =>
      _writesByPreferences[_preferences] ??= _DraftWrites();

  int get revision => _writes.revisions[connectionIdentity] ?? 0;

  String _component(String value) => base64Url.encode(utf8.encode(value));

  String _profilePrefix(String profileName) =>
      'composer_work_v3.${_component(connectionIdentity)}.'
      '${_component(profileName)}.';

  String _recordKey(String profileName, String sessionId) {
    if (profileName.isEmpty || sessionId.isEmpty) {
      throw ArgumentError('A profile and conversation identity are required');
    }
    return '${_profilePrefix(profileName)}${_component(sessionId)}';
  }

  List<ComposerDraftSummary> summaries({required String profileName}) {
    return [
      for (final key in _preferences.getKeys())
        if (key.startsWith(_profilePrefix(profileName)))
          for (final record in [?_readRecord(key)])
            if (record['profile'] == profileName &&
                record['session'] is String &&
                (record['session'] as String).isNotEmpty &&
                record['text'] is String &&
                record['attachments'] is List)
              (
                sessionId: record['session'] as String,
                text: record['text'] as String,
                attachmentCount: (record['attachments'] as List).length,
                queuedCount: record['queue'] is List
                    ? (record['queue'] as List).length
                    : 0,
                submissionUncertain: record['submission_uncertain'] == true,
              ),
    ];
  }

  Future<ComposerDraftSnapshot?> read({
    required String profileName,
    required String sessionId,
  }) async {
    final record = _readRecord(_recordKey(profileName, sessionId));
    if (record == null) return null;
    return _decodeRecord(record);
  }

  Future<void> write({
    required String profileName,
    required String sessionId,
    required String text,
    Iterable<ComposerReference> references = const [],
    required Iterable<AttachmentDraft> attachments,
    bool submissionUncertain = false,
    Iterable<QueuedPromptDraft> queuedPrompts = const [],
    bool queuePaused = false,
  }) {
    final key = _recordKey(profileName, sessionId);
    final files = attachments.toList(growable: false);
    final queue = queuedPrompts.toList(growable: false);
    // Capture mutable attachment/queue state before waiting for an older write.
    // Typing in one conversation never reads or encodes another conversation.
    final encoded = text.isNotEmpty || files.isNotEmpty || queue.isNotEmpty
        ? jsonEncode(
            _encodeRecord(
              profileName: profileName,
              sessionId: sessionId,
              text: text,
              references: references.toList(growable: false),
              attachments: files,
              submissionUncertain: submissionUncertain,
              queuedPrompts: queue,
              queuePaused: queuePaused,
            ),
          )
        : null;
    return _ordered([key], () => _commit(key, encoded));
  }

  Future<ComposerDraftSnapshot?> move({
    required String profileName,
    required String fromSessionId,
    required String toSessionId,
    bool forNewSession = false,
  }) {
    if (fromSessionId == toSessionId) {
      throw ArgumentError('Draft destination must be new.');
    }
    final sourceKey = _recordKey(profileName, fromSessionId);
    final destinationKey = _recordKey(profileName, toSessionId);
    // Reserve both records before attachment decoding can yield. Edits through
    // any store sharing these preferences cannot overtake the transfer.
    return _ordered([sourceKey, destinationKey], () async {
      if (_preferences.containsKey(destinationKey)) {
        throw StateError('The replacement chat already has a draft.');
      }
      final record = _readRecord(sourceKey);
      if (record == null) return null;
      final snapshot = forNewSession
          ? await _decodeRecord(record, forNewSession: true)
          : null;
      if (forNewSession && snapshot == null) {
        throw StateError('The saved draft could not be read.');
      }
      final destination = snapshot == null
          ? {...record, 'session': toSessionId}
          : _encodeRecord(
              profileName: profileName,
              sessionId: toSessionId,
              text: snapshot.text,
              references: snapshot.references,
              attachments: snapshot.attachments,
              submissionUncertain: snapshot.submissionUncertain,
              queuedPrompts: snapshot.queuedPrompts,
              queuePaused: true,
            );
      // Save before removing the source. Preferences cannot atomically move
      // two keys: an interrupted transfer can leave two recoverable copies.
      await _commit(destinationKey, jsonEncode(destination));
      try {
        await _commit(sourceKey, null);
      } catch (_) {
        try {
          await _commit(destinationKey, null);
        } catch (_) {
          // Keep the recoverable copies if rollback also fails.
        }
        rethrow;
      }
      return snapshot;
    });
  }

  Future<T> _ordered<T>(List<String> keys, Future<T> Function() action) {
    final pending = [
      for (final key in keys)
        if (_writes.tails[key] != null) _writes.tails[key]!,
    ];
    final writing = pending.isEmpty
        ? Future<T>.sync(action)
        : Future.wait(pending).then((_) => action());
    final settled = writing.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    for (final key in keys) {
      _writes.tails[key] = settled;
    }
    unawaited(
      settled.then((_) {
        for (final key in keys) {
          if (identical(_writes.tails[key], settled)) _writes.tails.remove(key);
        }
      }),
    );
    return writing;
  }

  Future<void> _commit(String key, String? encoded) async {
    final previous = _preferences.get(key);
    if (previous == encoded) return;
    try {
      final saved = encoded == null
          ? await _preferences.remove(key)
          : await _preferences.setString(key, encoded);
      if (!saved) throw StateError('Could not save unsent messages.');
    } catch (_) {
      // SharedPreferences updates its in-memory value before the platform write.
      // Restore this record on failure so an unsuccessful save is not presented
      // as durable work. A failing restore must not hide the original error.
      try {
        await switch (previous) {
          null => _preferences.remove(key),
          String value => _preferences.setString(key, value),
          bool value => _preferences.setBool(key, value),
          int value => _preferences.setInt(key, value),
          double value => _preferences.setDouble(key, value),
          List<String> value => _preferences.setStringList(key, value),
          _ => throw StateError('Unsupported saved draft value'),
        };
      } catch (_) {}
      rethrow;
    }
    _writes.revisions[connectionIdentity] = revision + 1;
  }

  Future<ComposerDraftSnapshot?> _decodeRecord(
    Map<String, dynamic> record, {
    bool forNewSession = false,
  }) async {
    final text = record['text'];
    final rawAttachments = record['attachments'];
    if (text is! String ||
        rawAttachments is! List ||
        record['references'] is! List) {
      return null;
    }
    return ComposerDraftSnapshot(
      text: text,
      references: ComposerReference.decode(record['references']),
      attachments: await _decodeAttachments(
        rawAttachments,
        forNewSession: forNewSession,
      ),
      submissionUncertain: record['submission_uncertain'] == true,
      queuedPrompts: await _decodeQueue(
        record['queue'],
        forNewSession: forNewSession,
      ),
      queuePaused: forNewSession || record['queue_paused'] == true,
    );
  }

  Map<String, dynamic> _encodeRecord({
    required String profileName,
    required String sessionId,
    required String text,
    required Iterable<AttachmentDraft> attachments,
    required bool submissionUncertain,
    required Iterable<ComposerReference> references,
    required Iterable<QueuedPromptDraft> queuedPrompts,
    required bool queuePaused,
  }) => {
    'profile': profileName,
    'session': sessionId,
    'text': text,
    'references': references.map((r) => r.toJson()).toList(),
    'submission_uncertain': submissionUncertain,
    'queue': queuedPrompts.map(_encodeQueuedPrompt).toList(),
    'queue_paused': queuePaused,
    'attachments': attachments.map(_encodeAttachment).toList(),
  };

  Map<String, dynamic>? _readRecord(String key) {
    final raw = _preferences.get(key);
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final record = Map<String, dynamic>.from(decoded);
      final profile = record['profile'];
      final session = record['session'];
      if (profile is! String ||
          session is! String ||
          _recordKey(profile, session) != key) {
        return null;
      }
      return record;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _encodeAttachment(AttachmentDraft draft) => {
    'id': draft.id,
    'path': draft.cachedPath,
    'name': draft.name,
    'bytes': draft.byteLength,
    'media_type': draft.mediaType,
    'kind': draft.kind.name,
    'source_image_format': draft.sourceImageFormat?.name,
    'sanitized': draft.sanitized,
    'status': draft.status.name,
    'ref_text': draft.refText,
    'image_path': draft.imagePath,
    'attached_session_id': draft.attachedSessionId,
    'error': draft.error,
    'atlas_intake_accepted': draft.atlasIntakeAccepted,
  };

  Map<String, dynamic> _encodeQueuedPrompt(QueuedPromptDraft prompt) => {
    'text': prompt.text,
    if (prompt.voiceContext != null) 'voice_context': prompt.voiceContext,
    if (prompt.submissionId != null) 'submission_id': prompt.submissionId,
    if (prompt.submissionPayload != null)
      'submission_payload': prompt.submissionPayload,
    'references': prompt.references.map((r) => r.toJson()).toList(),
    'attachments': prompt.attachments.map(_encodeAttachment).toList(),
    if (prompt.submissionUncertain) 'submission_uncertain': true,
  };

  Future<List<QueuedPromptDraft>> _decodeQueue(
    Object? value, {
    bool forNewSession = false,
  }) async {
    if (value is! List) return [];
    final queued = <QueuedPromptDraft>[];
    for (final entry in value) {
      try {
        final record = Map<String, dynamic>.from(entry as Map);
        final text = record['text'];
        final rawAttachments = record['attachments'];
        final submissionUncertain = record['submission_uncertain'];
        if (text is! String ||
            rawAttachments is! List ||
            record['references'] is! List ||
            (submissionUncertain != null && submissionUncertain is! bool)) {
          throw const FormatException('Invalid queued prompt');
        }
        final attachments = await _decodeAttachments(
          rawAttachments,
          forNewSession: forNewSession,
        );
        if (text.trim().isNotEmpty || attachments.isNotEmpty) {
          queued.add(
            QueuedPromptDraft(
              text: text,
              voiceContext: record['voice_context'] as String?,
              references: ComposerReference.decode(record['references']),
              attachments: attachments,
              submissionUncertain: submissionUncertain == true,
              submissionId: record['submission_id'] as String?,
              submissionPayload: record['submission_payload'] is Map
                  ? Map<String, dynamic>.from(
                      record['submission_payload'] as Map,
                    )
                  : null,
            ),
          );
        }
      } catch (_) {
        // One damaged queue entry must not discard the other unsent work.
      }
    }
    return queued;
  }

  Future<List<AttachmentDraft>> _decodeAttachments(
    List<dynamic> values, {
    bool forNewSession = false,
  }) async {
    const missingFile = 'File missing. Remove and reattach.';
    final attachments = <AttachmentDraft>[];
    for (final value in values) {
      try {
        final draft = _decodeAttachment(
          Map<String, dynamic>.from(value as Map),
        );
        final hasReusableReference =
            !forNewSession && draft.hasGatewayAttachment;
        final cachedFileExists = hasReusableReference
            ? true
            : await File(draft.cachedPath).exists();
        if (forNewSession) {
          draft
            ..refText = null
            ..imagePath = null
            ..attachedSessionId = null
            ..atlasIntakeAccepted = null;
          if (!cachedFileExists) {
            draft
              ..status = AttachmentDraftStatus.failed
              ..error = missingFile;
          } else if (draft.status == AttachmentDraftStatus.attached ||
              draft.status == AttachmentDraftStatus.uploading) {
            draft
              ..status = AttachmentDraftStatus.ready
              ..error = null;
          }
        } else if (!cachedFileExists) {
          draft
            ..status = AttachmentDraftStatus.failed
            ..error = missingFile;
        } else if (draft.status == AttachmentDraftStatus.uploading) {
          draft.status = AttachmentDraftStatus.ready;
        }
        attachments.add(draft);
      } catch (_) {
        // One damaged attachment record must not discard the user's text.
      }
    }
    return attachments;
  }

  AttachmentDraft _decodeAttachment(Map<String, dynamic> value) {
    T enumValue<T extends Enum>(List<T> values, Object? name) =>
        values.singleWhere((candidate) => candidate.name == name);

    final id = value['id'];
    final path = value['path'];
    final name = value['name'];
    final bytes = value['bytes'];
    final mediaType = value['media_type'];
    if (id is! String ||
        id.isEmpty ||
        path is! String ||
        path.isEmpty ||
        name is! String ||
        name.isEmpty ||
        bytes is! int ||
        bytes <= 0 ||
        mediaType is! String ||
        mediaType.isEmpty) {
      throw const FormatException('Invalid attachment draft');
    }
    final sourceFormat = value['source_image_format'];
    return AttachmentDraft(
      id: id,
      cachedPath: path,
      name: name,
      byteLength: bytes,
      mediaType: mediaType,
      kind: enumValue(AttachmentDraftKind.values, value['kind']),
      sourceImageFormat: sourceFormat == null
          ? null
          : enumValue(AttachmentImageFormat.values, sourceFormat),
      sanitized: value['sanitized'] == true,
      status: enumValue(AttachmentDraftStatus.values, value['status']),
      refText: value['ref_text'] as String?,
      imagePath: value['image_path'] as String?,
      attachedSessionId: value['attached_session_id'] as String?,
      error: value['error'] as String?,
      atlasIntakeAccepted: value['atlas_intake_accepted'] as bool?,
    );
  }
}
