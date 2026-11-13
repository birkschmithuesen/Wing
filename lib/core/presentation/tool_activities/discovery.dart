part of '../tool_activity_details.dart';

/// Discovery is capability reading, not operation execution or a schema editor.
void _toolSearch(_ToolProjection p) {
  p.options(p.args, const {'limit': 'Limit'});
  final groups = _maps(p.data['results']);
  final requested = _discoveryStrings(p.args['queries']);
  final queries = groups.isEmpty
      ? requested
      : groups.map((group) => _text(group['query']) ?? '').toList();
  p.intent = queries.where((query) => query.isNotEmpty).join(' · ');
  final tools = p.data['tools'] is Map ? p.data['tools'] as Map : const {};
  if (groups.isEmpty) {
    for (final query in requested) {
      p.addRequest('Query', query, role: ToolDetailRole.search);
    }
  }
  for (var index = 0; index < groups.length; index++) {
    final group = groups[index];
    final query =
        _text(group['query']) ??
        (index < requested.length ? requested[index] : null);
    p.addRequest('Query', query, role: ToolDetailRole.search);
    final matches = _discoveryStrings(group['matches']);
    if (matches.isEmpty) {
      p.addResponse('Result', 'No matching tools were returned.');
      for (final source in _maps(group['available_sources'])) {
        final name = _text(source['name']);
        if (name == null) continue;
        final unavailable = _text(source['unavailable']);
        p.addResponse(
          'Available source',
          name,
          facts: [
            if (source['tool_count'] is num) 'Tools: ${source['tool_count']}',
          ],
        );
        p.warning(unavailable, label: '$name · Unavailable');
      }
      p.addResponse('Search guidance', group['hint']);
    }
    for (final name in matches) {
      final record = tools[name];
      final description = record is Map ? _text(record['description']) : null;
      final source = record is Map ? _text(record['source_name']) : null;
      p.addResponse(
        _discoveryName(name),
        description ?? 'No description was supplied.',
        facts: _discoverySourceFacts(name, source: source),
      );
    }
  }
  _discoveryConnectorWarning(p);
}

void _toolDescribe(_ToolProjection p) {
  final names = _discoveryStrings(p.args['names']);
  p.intent = names.map(_discoveryName).join(' · ');
  final tools = p.data['tools'];
  if (tools is Map) {
    for (final entry in tools.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final name = entry.key as String;
      final record = entry.value as Map;
      p.addResponse(
        _discoveryName(name),
        _text(record['description']) ?? 'No description was supplied.',
        facts: _discoverySourceFacts(name),
      );
      // Exact parameter schemas remain in Raw details, without main actions.
    }
  }
  for (final name in names) {
    p.addRequest(
      'Requested tool',
      _discoveryName(name),
      facts: _discoverySourceFacts(name),
    );
  }
  for (final name in _discoveryStrings(p.data['not_found'])) {
    p.warning(
      'This tool is not currently available.',
      label: '${_discoveryName(name)} · Unavailable',
    );
  }
  if (p.data['errors'] case final Map errors) {
    for (final entry in errors.entries) {
      if (entry.key is String && entry.value is String) {
        p.warning(
          entry.value,
          label:
              '${_discoveryName(entry.key as String)} · Description unavailable',
        );
      }
    }
  }
  p.addResponse('Discovery guidance', p.data['hint']);
  _discoveryConnectorWarning(p);
  if (tools is Map &&
      tools.isEmpty &&
      _discoveryStrings(p.data['not_found']).isEmpty &&
      p.data['errors'] is! Map &&
      p.data['connectors'] is! Map) {
    p.addResponse('Result', 'No tool descriptions were returned.');
  }
}

/// Only the verified Hermes connector envelope is interpreted here. Vendor
/// response objects remain one received payload, with no domain-status guesses.
void _toolCall(_ToolProjection p) {
  final calls = _maps(p.args['calls']);
  p.intent = calls
      .map((call) => _text(call['name']))
      .whereType<String>()
      .map(_discoveryName)
      .join(' · ');
  for (final call in calls) {
    final name = _text(call['name']);
    if (name == null) continue;
    _invocationRequest(p, name, call['arguments']);
  }
  final entries = _maps(p.data['results']);
  var failures = 0;
  for (final entry in entries) {
    final name = _text(entry['name']);
    final title = name == null ? 'Operation' : _discoveryName(name);
    final facts = name == null ? const <String>[] : _discoverySourceFacts(name);
    if (entry.containsKey('error')) {
      failures++;
      final error = entry['error'];
      final message = error is Map ? _text(error['message']) : _text(error);
      p.addResponse(
        '$title · Error',
        message ?? 'The operation returned an error.',
        role: ToolDetailRole.warning,
        facts: facts,
      );
      if (error is Map) {
        p.addResponse('$title · Recovery', error['hint']);
        final link = _web(error['connect_url']);
        if (link != null) {
          p.addResponse(
            '$title · Connect account',
            'Open the supplied account authorization link.',
            link: link,
            facts: facts,
          );
        }
      }
    } else if (entry.containsKey('response')) {
      final value = entry['response'];
      p.addResponse(
        '$title · Result',
        value == null || (value is String && value.trim().isEmpty)
            ? 'No response content was supplied.'
            : _literal(value),
        format: value is Map || value is List
            ? ToolDetailFormat.source
            : ToolDetailFormat.prose,
        role: ToolDetailRole.output,
        copyable: value is String && value.trim().isNotEmpty,
        facts: facts,
      );
    }
  }
  if (failures > 0) {
    p.state = failures == entries.length
        ? ToolReceiptState.error
        : ToolReceiptState.warning;
    p.status = failures == entries.length
        ? 'Operations failed'
        : 'Completed with operation errors';
  }
  if (entries.length > 1) {
    p.fact('Responses', p.data['success_count'], result: true);
    p.fact('Errors', p.data['error_count'], result: true);
    p.fact('Operations', p.data['total_count'], result: true);
  }
  // A bridge-level validation error may include a giant parameters schema.
  // finish() owns the error message; schemas and constraints stay in Raw.
  if (p.data['error'] != null) p.addResponse('Recovery', p.data['hint']);
  if (entries.isEmpty && p.output is String) {
    p.addResponse('Result', p.output, copyable: true);
  }
}

void _invocationRequest(_ToolProjection p, String name, Object? arguments) {
  final title = _discoveryName(name);
  final facts = _discoverySourceFacts(name);
  var added = false;
  if (arguments is Map) {
    // These are received reusable text payloads, not an assumed remote schema.
    // IDs, flags, options and arbitrary nested maps never get generic panels.
    for (final key in const [
      'query',
      'prompt',
      'title',
      'subject',
      'body',
      'text',
      'content',
      'command',
      'code',
    ]) {
      final value = _text(arguments[key]);
      if (value == null) continue;
      added = true;
      final literal = key == 'command' || key == 'code';
      p.addRequest(
        '$title · ${_discoveryName(key)}',
        value,
        format: literal ? ToolDetailFormat.source : ToolDetailFormat.prose,
        role: key == 'command'
            ? ToolDetailRole.command
            : key == 'code'
            ? ToolDetailRole.code
            : ToolDetailRole.text,
        copyable: key != 'query' && key != 'title' && key != 'subject',
        facts: facts,
      );
    }
  }
  if (!added) p.addRequest('Operation', title, facts: facts);
}

/// Finished decisions are passive; the pending-question owner retains all locks
/// and interactive controls. A timed-out wait can still contain answered rows.
void _clarify(_ToolProjection p) {
  final responses = _maps(p.data['responses']);
  final questions = _maps(p.args['questions']);
  p.intent = (questions.isEmpty ? responses : questions)
      .map((question) => _text(question['question']))
      .whereType<String>()
      .join(' · ');
  final count = responses.length > questions.length
      ? responses.length
      : questions.length;
  for (var index = 0; index < count; index++) {
    final response = index < responses.length ? responses[index] : const {};
    final question = index < questions.length ? questions[index] : const {};
    final text = _text(response['question']) ?? _text(question['question']);
    p.addRequest('Question', text, role: ToolDetailRole.question);
    final choices = response.containsKey('choices_offered')
        ? _discoveryStrings(response['choices_offered'])
        : _discoveryStrings(question['choices']);
    if (choices.isNotEmpty) {
      p.addRequest('Choices', choices.map((choice) => '• $choice').join('\n'));
    }
    final status = _text(response['status']);
    if (status == null) continue;
    final answer = response['user_response'];
    final label = count > 1 ? 'Question ${index + 1} · Answer' : 'Answer';
    if (status == 'answered' && answer is String && answer.isNotEmpty) {
      p.addResponse(
        label,
        answer,
        role: ToolDetailRole.question,
        copyable: !choices.contains(answer),
        facts: const ['Answered'],
      );
    } else if (status == 'answered' && answer is List) {
      final selected = _discoveryStrings(answer);
      p.addResponse(
        label,
        selected.map((value) => '• $value').join('\n'),
        role: ToolDetailRole.question,
        facts: const ['Answered'],
      );
    } else if (status == 'skipped' || status == 'unanswered') {
      p.addResponse(
        label,
        status == 'skipped' ? 'Skipped' : 'Unanswered',
        role: ToolDetailRole.question,
      );
    }
  }
  final notice = _text(p.data['notice']);
  var noticeUsed = false;
  switch (p.data['outcome']) {
    case 'timed_out':
      p.warning(
        notice ?? 'The wait ended before all questions were answered.',
        label: 'Questions timed out',
      );
      noticeUsed = true;
    case 'cancelled':
      p.warning(
        notice ?? 'The question request was cancelled.',
        label: 'Questions cancelled',
      );
      noticeUsed = true;
    case 'undelivered':
      p.warning(
        notice ?? 'The question request was not delivered to a client.',
        label: 'Questions not delivered',
      );
      noticeUsed = true;
  }
  if (!noticeUsed) {
    p.addResponse('Notice', notice, role: ToolDetailRole.warning);
  }
}

List<String> _discoveryStrings(Object? value) => value is List
    ? value.whereType<String>().where((text) => text.trim().isNotEmpty).toList()
    : const [];

String _discoveryName(String name) {
  final parts = name.split('__');
  final operation = parts.length >= 3 ? parts.skip(2).join('__') : name;
  final words = operation.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (words.isEmpty) return name;
  return '${words[0].toUpperCase()}${words.substring(1).toLowerCase()}';
}

List<String> _discoverySourceFacts(String name, {String? source}) {
  final parts = name.split('__');
  final identity = source ?? (parts.length >= 3 ? parts[1] : null);
  return identity == null || identity.isEmpty
      ? const []
      : ['Source: $identity'];
}

void _discoveryConnectorWarning(_ToolProjection p) {
  if (p.data['connectors'] case final Map connectors) {
    if (connectors['status'] != 'unavailable') return;
    final names = _discoveryStrings(connectors['names']);
    p.warning(
      _text(connectors['hint']) ?? 'Hosted connector tools are unavailable.',
      label: 'Connector discovery unavailable',
    );
    for (final name in names) {
      p.addResponse(
        '${_discoveryName(name)} · Description unavailable',
        'The connector description could not be retrieved.',
        facts: _discoverySourceFacts(name),
      );
    }
  }
}
