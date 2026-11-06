import 'dart:convert';

import 'answer_versions.dart';
import 'user_message_content.dart';
import 'composer_reference.dart';

/// Fields that describe a saved row's reading presentation, never live state.
/// Capture is shallow: large content is validated by the snapshot encoder after
/// it has selected the worker path, rather than walking it on the UI isolate.
Map<String, dynamic> captureReadingSnapshotMessage(Map<String, dynamic> row) =>
    {
      for (final key in [
        'id',
        'row_id',
        'role',
        'content',
        'text',
        'timestamp',
        '_reply_turn',
        '_reply_segment',
        '_reply_offset',
        '_reply_sealed',
        '_reply_admission',
        '_reply_streaming',
        'hidden',
        '_todo_snapshot_synthetic',
        if (row['role'] == 'system') '_review_notice',
        'display_kind',
        'display_content',
        if (row['role'] == 'tool') ...[
          'tool_call_id',
          'tool_name',
          'args',
          'context',
          'summary',
          'labels',
          'duration_s',
        ],
      ])
        if (row.containsKey(key)) key: row[key],
      if (row['display_metadata'] case final Map metadata)
        'display_metadata': {
          for (final key in ['task_count', 'display_text', 'model_only'])
            if (metadata.containsKey(key)) key: metadata[key],
        },
      if (row['submitted_attachments'] is List)
        'submitted_attachments': [
          for (final attachment in readingSnapshotAttachments(
            row['submitted_attachments'],
          ))
            attachment.toReadingJson(),
        ],
    };

/// A bounded, typed JSON projection of the display fields understood by the
/// transcript. Notice metadata retains its title/count and model-only marker;
/// arbitrary nested gateway records and decision/transport fields are excluded.
Map<String, dynamic> projectReadingSnapshotMessage(Map row) {
  final result = <String, dynamic>{};
  for (final key in ['id', 'row_id']) {
    final value = row[key];
    if (value is int || value is String) result[key] = value;
  }
  for (final key in ['_reply_turn', '_reply_admission']) {
    final value = row[key];
    if (value is String && value.isNotEmpty && value.length <= 256) {
      result[key] = value;
    }
  }
  final segment = row['_reply_segment'];
  if (segment is int && segment >= 0) result['_reply_segment'] = segment;
  if (row['_reply_streaming'] == true) result['_reply_streaming'] = true;
  if (row['_reply_sealed'] == true) result['_reply_sealed'] = true;
  final offset = row['_reply_offset'];
  if (offset is int && offset >= 0) result['_reply_offset'] = offset;
  for (final key in ['role', 'display_kind']) {
    final value = row[key];
    if (value is String && value.length <= 128) result[key] = value;
  }
  for (final key in ['hidden', '_todo_snapshot_synthetic']) {
    final value = row[key];
    if (value is bool) result[key] = value;
  }
  final timestamp = row['timestamp'];
  if (timestamp is num && timestamp.isFinite) result['timestamp'] = timestamp;
  for (final key in ['content', 'text', 'display_content']) {
    final value = _content(row[key]);
    final prepared = row['role'] == 'user'
        ? PreparedComposerMessage.fromContent(value)
        : null;
    if (prepared != null) {
      final display =
          '${PreparedComposerMessage(message: prepared.message, context: '', references: prepared.references).wireText}${prepared.imageReferences}';
      result[key] = value is List
          ? [
              {'type': 'text', 'text': display},
              ...value.whereType<Map>().where(
                (part) => {
                  'image_url',
                  'input_image',
                  'image',
                }.contains(part['type']),
              ),
            ]
          : display;
    } else if (value != null) {
      result[key] = value;
    }
  }
  // This marker identifies a received, client-owned reading receipt. It gives
  // no runtime authority and must survive the next authoritative history read.
  final review = row['_review_notice'];
  if (result['role'] == 'system' &&
      result['content'] is String &&
      (result['content'] as String).startsWith('review:') &&
      review is String &&
      review.isNotEmpty) {
    result['_review_notice'] = review;
  }
  final metadata = answerMessageDisplayMetadata(Map<String, dynamic>.from(row));
  final displayMetadata = <String, dynamic>{};
  if (metadata['model_only'] case final bool modelOnly) {
    displayMetadata['model_only'] = modelOnly;
  }
  if (const {
    'async_delegation_complete',
    'process_complete',
  }.contains(result['display_kind'])) {
    final display = metadata['display_text'];
    if (display is String && display.trim().isNotEmpty) {
      displayMetadata['display_text'] = display;
    }
  }
  if (result['display_kind'] == 'async_delegation_complete') {
    final count = metadata['task_count'];
    if (count is num &&
        count.isFinite &&
        count > 0 &&
        count <= 0x7fffffff &&
        count == count.round()) {
      displayMetadata['task_count'] = count.toInt();
    }
  }
  if (displayMetadata.isNotEmpty) result['display_metadata'] = displayMetadata;
  if (row['submitted_attachments'] is List) {
    result['submitted_attachments'] = [
      for (final attachment in readingSnapshotAttachments(
        row['submitted_attachments'],
      ))
        attachment.toReadingJson(),
    ];
  }
  if (result['role'] == 'tool') {
    for (final key in ['tool_call_id', 'tool_name', 'context', 'summary']) {
      final value = row[key];
      if (value is String && value.trim().isNotEmpty) result[key] = value;
    }
    final seconds = row['duration_s'];
    if (seconds is num && seconds.isFinite && seconds >= 0) {
      result['duration_s'] = seconds;
    }
    final args = row['args'];
    if (args is String) result['args'] = args;
    if (args is Map) result['args'] = jsonEncode(args);
    if (row['labels'] case final List labels) {
      result['labels'] = [
        for (final label in labels)
          if (label is Map &&
              label['text'] is String &&
              label['name'] is String)
            {
              'text': label['text'],
              'name': label['name'],
              if (label['preview'] is String) 'preview': label['preview'],
            },
      ];
    }
  }
  return result;
}

/// Restore the existing typed presentation list at the storage boundary. Neither
/// this list nor its names/references can acknowledge an upload or a decision.
List<UserMessageAttachment> readingSnapshotAttachments(Object? value) {
  if (value is! List) return [];
  return [
    for (final item in value.take(16))
      if (item is UserMessageAttachment && item.canCacheReadingMetadata)
        item
      else if (item is! UserMessageAttachment)
        ?UserMessageAttachment.fromReadingJson(item),
  ];
}

Object? _content(Object? value) {
  if (value is String) return value;
  if (value is Map) return _part(value);
  // A row can have a bounded list of content parts, but cannot carry an
  // arbitrary-depth nested document through a recognized display field.
  if (value is! List || value.length > 256) return null;
  final parts = <Object>[];
  for (final part in value) {
    if (part is String) {
      parts.add(part);
    } else if (part is Map) {
      final projected = _part(part);
      if (projected != null) parts.add(projected);
    }
  }
  return parts;
}

Map<String, dynamic>? _part(Map part) {
  final type = part['type'];
  if (type != null && (type is! String || type.length > 128)) return null;
  final result = <String, dynamic>{
    if (type is String) 'type': type,
    if (part['text'] is String) 'text': part['text'],
    if (const {'text', 'input_text', 'output_text'}.contains(type) &&
        part['content'] is String)
      'content': part['content'],
  };
  if (const {'image_url', 'input_image', 'image'}.contains(type)) {
    for (final key in ['name', 'url']) {
      if (part[key] is String) result[key] = part[key];
    }
    final image = part['image_url'];
    if (image is String) {
      result['image_url'] = image;
    } else if (image is Map && image['url'] is String) {
      result['image_url'] = {'url': image['url']};
    }
  }
  return result.isEmpty ? null : result;
}
