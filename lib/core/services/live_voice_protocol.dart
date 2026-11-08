import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/app_preferences.dart';

sealed class VoiceProtocolEvent {}

final class VoiceReady extends VoiceProtocolEvent {}

final class VoiceClosed extends VoiceProtocolEvent {
  VoiceClosed(this.reason);
  final String? reason;
}

final class VoiceCommandError extends VoiceProtocolEvent {}

final class VoiceTranscript extends VoiceProtocolEvent {
  VoiceTranscript(this.user, this.text, {this.complete = false, this.id});
  final bool user;
  final String text;
  final bool complete;
  final String? id;
}

final class VoiceDelegation extends VoiceProtocolEvent {
  VoiceDelegation(this.id, this.action, this.text);
  final String id;
  final String action;
  final String text;
}

/// These are two distinct GPT-Live APIs. No legacy Realtime events or fallback.
class LiveVoiceProtocol {
  LiveVoiceProtocol(this.mode);
  final LiveVoiceMode mode;
  final _seen = <String>{};
  final _transcripts = <String>{};
  String _pendingInput = '';
  bool _assistantSinceInput = false;
  bool get _api => mode == LiveVoiceMode.api;

  VoiceProtocolEvent? accept(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'session.started') return VoiceReady();
    if (type == 'error') return VoiceCommandError();
    if (type == 'session.closed' || type == 'session.error') {
      return VoiceClosed(
        event['reason'] is String ? event['reason'] as String : null,
      );
    }
    if (_api) {
      if (type == 'session.input_transcript.delta' ||
          type == 'session.output_transcript.delta') {
        final delta = event['delta'];
        if (delta is! String) return null;
        final user = type == 'session.input_transcript.delta';
        if (user) {
          if (_assistantSinceInput) _pendingInput = '';
          _assistantSinceInput = false;
          _pendingInput = _tail(_pendingInput + delta, 16000);
        } else if (delta.isNotEmpty) {
          // Keep this request through a spoken preamble before delegation;
          // retire it when the user begins the next conversational segment.
          _assistantSinceInput = true;
        }
        return VoiceTranscript(user, delta);
      }
      if (type != 'session.delegation.created') return null;
      final delegation = event['delegation'];
      if (delegation is! Map ||
          delegation['type'] != 'delegation' ||
          delegation['target'] != 'client' ||
          delegation['id'] is! String) {
        return null;
      }
      final id = delegation['id'] as String;
      if (!_seen.add(id)) return null;
      final text = _pendingInput.trim();
      _pendingInput = '';
      return _request(id, text);
    }
    final item = event['item'];
    if (type == 'input_transcript.added' || type == 'output_transcript.added') {
      if (item is Map && item['text'] is String) {
        final id = item['id'] is String ? item['id'] as String : null;
        if (id != null && !_transcripts.add('$type:$id')) return null;
        return VoiceTranscript(
          type == 'input_transcript.added',
          item['text'] as String,
          id: id,
        );
      }
    }
    if (type == 'turn.done') {
      final turn = event['turn'];
      if (turn is Map && turn['transcript'] is String) {
        final id = turn['id'] is String ? turn['id'] as String : null;
        if (id != null && !_transcripts.add('$type:$id')) return null;
        return VoiceTranscript(
          turn['role'] == 'user',
          turn['transcript'] as String,
          complete: true,
          id: id,
        );
      }
    }
    if (type != 'delegation.created' ||
        item is! Map ||
        item['type'] != 'delegation' ||
        item['target'] != 'client' ||
        item['id'] is! String) {
      return null;
    }
    final id = item['id'] as String;
    if (!_seen.add(id)) return null;
    final content = item['content'];
    final raw = content is List
        ? content
              .whereType<Map>()
              .where((v) => v['type'] == 'input_text')
              .map((v) => v['text'])
              .whereType<String>()
              .join('\n')
        : '';
    return _request(id, raw.trim());
  }

  // Both providers delegate prose. Only a whole explicit command controls work;
  // quoted commands and JSON are ordinary requests for Hermes to interpret.
  static VoiceDelegation _request(String id, String text) {
    if (text.isEmpty || text.length > 32000) {
      return VoiceDelegation(id, 'invalid', '');
    }
    final command = text
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .trim();
    final action = switch (command) {
      'stop the task' || 'stop working' || 'cancel the task' => 'stop',
      'task status' || 'how is the task going' => 'status',
      _ => 'request',
    };
    return VoiceDelegation(id, action, text);
  }

  List<Map<String, dynamic>> begin(String context) => _api
      ? [
          _apiAppend(
            'instructions',
            'Use the current Hermes chat for delegated work. Always delegate explicit requests to stop work or ask for task status. Talking over you stops speech, never the task. Do not claim completion until Hermes reports it.',
            null,
          ),
        ]
      : this.context(context);

  List<Map<String, dynamic>> result(String id, String text) => [
    for (final chunk in _chunks(text))
      _api
          ? _apiAppend('commentary', chunk, id)
          : {
              'type': 'delegation.context.append',
              'delegation_item_id': id,
              'channel': 'speakable',
              'content': [
                {'type': 'input_text', 'text': chunk},
              ],
            },
  ];
  List<Map<String, dynamic>> context(String text, {bool speak = false}) => [
    for (final chunk in _chunks(text))
      _api
          ? _apiAppend(speak ? 'commentary' : 'thinking', chunk, null)
          : {
              'type': 'session.context.append',
              'channel': speak ? 'speakable' : 'commentary',
              'content': [
                {'type': 'input_text', 'text': chunk},
              ],
            },
  ];
  Map<String, dynamic>? mute(bool value) => _api
      ? {
          'type': value
              ? 'session.input_audio.mute'
              : 'session.input_audio.unmute',
          'event_id': const Uuid().v4(),
        }
      : null;
  Map<String, dynamic> _apiAppend(String kind, String text, String? id) => {
    'type': 'session.$kind.append',
    'event_id': const Uuid().v4(),
    'delegation_id': id,
    'content': text,
  };
  // Both providers reject appends above 500 tokens. UTF-8 bytes bound tokens
  // conservatively; retain every character and split only at rune boundaries.
  static Iterable<String> _chunks(String text) sync* {
    var chunk = StringBuffer(), bytes = 0;
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune),
          size = utf8.encode(String.fromCharCode(rune)).length;
      if (bytes + size > 480) {
        yield chunk.toString();
        chunk = StringBuffer();
        bytes = 0;
      }
      chunk.write(char);
      bytes += size;
    }
    if (chunk.isNotEmpty) yield chunk.toString();
  }

  static String _tail(String text, int limit) =>
      text.length <= limit ? text : text.substring(text.length - limit);
}
